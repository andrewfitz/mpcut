import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptExternalCacheTests: XCTestCase {
    func testStandaloneCommandSharesCompletedTracksWithRetryAndLiveRunner() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let provider = environment["MPCUT_TEST_TRANSCRIBERRR_HELPER"],
              let cli = environment["MPCUT_TEST_TRANSCRIPT_CLI"] else {
            throw XCTSkip("Set MPCUT_TEST_TRANSCRIPT_CLI and MPCUT_TEST_TRANSCRIBERRR_HELPER to built binaries with local models.")
        }
        let ffmpeg = try XCTUnwrap([environment["MPCUT_TEST_FFMPEG"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MPCut-external-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TranscriptJobStore(directory: directory.appendingPathComponent("jobs"))
        let media = directory.appendingPathComponent("recording.mov")
        let wrapper = directory.appendingPathComponent("provider-entry")
        let launchLog = directory.appendingPathComponent("provider-launches")
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$*" >> "$MPCUT_TEST_PROVIDER_LOG"
        exec "$MPCUT_TEST_REAL_PROVIDER" "$@"
        """.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        // This process, the command-line tool and the provider exchange results in one folder.
        let claimsVariable = "MPCUT_TRANSCRIPT_CLAIMS_HOME"
        let claimsFolder = directory.appendingPathComponent("claims", isDirectory: true)
        let inheritedClaims = environment[claimsVariable]
        setenv(claimsVariable, claimsFolder.path, 1)
        defer {
            if let inheritedClaims { setenv(claimsVariable, inheritedClaims, 1) } else { unsetenv(claimsVariable) }
        }
        let processEnvironment = environment.merging([
            claimsVariable: claimsFolder.path,
            "MPCUT_TRANSCRIBERRR_HELPER": wrapper.path,
            "MPCUT_TEST_PROVIDER_LOG": launchLog.path,
            "MPCUT_TEST_REAL_PROVIDER": provider,
        ]) { _, new in new }

        func invoke(_ arguments: [String], overrides: [String: String] = [:]) throws -> Data {
            let program = try XCTUnwrap(arguments.first)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = Array(arguments.dropFirst())
            process.currentDirectoryURL = directory
            process.environment = processEnvironment.merging(overrides) { _, new in new }
            let output = directory.appendingPathComponent("stdout")
            let error = directory.appendingPathComponent("stderr")
            try Data().write(to: output)
            try Data().write(to: error)
            let stdout = try FileHandle(forWritingTo: output)
            let stderr = try FileHandle(forWritingTo: error)
            defer { try? stdout.close(); try? stderr.close() }
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            let diagnostic = String(decoding: try Data(contentsOf: error), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, diagnostic)
            return try Data(contentsOf: output)
        }

        struct Receipt: Decodable {
            struct Session: Decodable { let command: [String] }
            let id: UUID
            let sessions: [Session]
        }

        func mpcut(_ command: [String], _ arguments: [String]) throws -> Data {
            try invoke([cli, "transcript"] + command + ["--job-directory", store.directory.path, "--json"] + arguments)
        }
        func prepare() throws -> Receipt {
            let options = directory.appendingPathComponent("prepare-request.json")
            try JSONSerialization.data(withJSONObject: [
                "file": media.path, "job_directory": store.directory.path,
                "engine": "parakeet-v3", "diarization": false,
            ]).write(to: options)
            let report = try invoke([cli, "transcript", "job", "prepare", "--input", options.path, "--json"])
            return try JSONDecoder().decode(Receipt.self, from: report)
        }
        func providerEvents(_ command: [String], overrides: [String: String] = [:]) throws -> [[String: Any]] {
            let log = try invoke(command, overrides: overrides)
            return try log.split(separator: 10).map { line in
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            }
        }
        func processed(_ events: [[String: Any]]) -> Set<String> {
            Set(events.filter { $0["event"] as? String == "track_progress" }.compactMap { $0["track_id"] as? String })
        }
        func removeExchangeFiles(for job: TranscriptJobRecord) {
            guard let cacheDirectory = try? TranscriptRecognitionClaims.directory() else { return }
            for track in job.sessions.flatMap(\.tracks) {
                guard let stream = track.streamIndex, let result = track.result,
                      let key = TranscriptRecognitionCache.Artifacts(result: result, activity: track.activity)?.recognitionKey
                else { continue }
                let scope = TranscriptExternalCacheDescriptor.scope(for: track.file, stream: stream)
                let id = TranscriptExternalCacheDescriptor.claimID(scope: scope, key: key)
                try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(id + ".json"))
                try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(id + ".mpx"))
                try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(id))
            }
        }

        _ = try invoke([ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error",
                        "-f", "lavfi", "-i", "sine=f=340:r=16000:d=1",
                        "-f", "lavfi", "-i", "sine=f=530:r=16000:d=1",
                        "-map", "0:a", "-map", "1:a", "-c:a", "pcm_s16le", media.path])
        let prepared = try prepare()
        let initial = try store.status(prepared.id)
        defer { removeExchangeFiles(for: initial) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchLog.path))
        let stagedTracks = try XCTUnwrap(initial.sessions.first?.tracks)
        XCTAssertEqual(stagedTracks.count, 2)
        let healthy = try XCTUnwrap(stagedTracks.first)
        let missing = try XCTUnwrap(stagedTracks.last)
        try FileManager.default.removeItem(at: XCTUnwrap(missing.audio))
        let first = try providerEvents(XCTUnwrap(prepared.sessions.first?.command))
        XCTAssertEqual(first.last?["status"] as? String, "partial")
        XCTAssertEqual(processed(first), Set(stagedTracks.map(\.id)))
        let firstResult = try XCTUnwrap(healthy.result)
        let recognitionSnapshot = try SourceIdentity(firstResult)

        _ = try mpcut(["attachment", "import"], ["--file", media.path, "--job-id", prepared.id.uuidString,
                                 "--output", directory.appendingPathComponent("partial.json").path])
        XCTAssertEqual(try store.status(prepared.id).state, .partial)
        let artifact = try XCTUnwrap(TranscriptRecognitionCache.Artifacts(result: firstResult, activity: healthy.activity))
        let key = try XCTUnwrap(artifact.recognitionKey)
        let sidecar = AnalysisSidecar(source: media, identity: try SourceIdentity(media))
        let cache = TranscriptRecognitionCache(sidecar: sidecar, key: key, evidence: healthy.evidence,
                                               stream: try XCTUnwrap(healthy.streamIndex))
        XCTAssertNotNil(sidecar.read(cache.section))
        let retry = try JSONDecoder().decode(Receipt.self, from: mpcut(["job", "retry"], ["--job-id", prepared.id.uuidString]))
        let retried = try providerEvents(XCTUnwrap(retry.sessions.first?.command))
        XCTAssertEqual(retried.last?["status"] as? String, "completed")
        XCTAssertEqual(processed(retried), [missing.id])
        XCTAssertTrue(recognitionSnapshot.matchesSnapshot(try SourceIdentity(firstResult)))

        let standalone = try XCTUnwrap(retry.sessions.first?.command)
        let emptyModels = directory.appendingPathComponent("empty-models")
        try FileManager.default.createDirectory(at: emptyModels, withIntermediateDirectories: false)
        let pinned = try providerEvents(standalone + ["--reconcile-only"],
                                        overrides: ["TRANSCRIBERRR_MODEL_CACHE": emptyModels.path])
        XCTAssertEqual(pinned.last?["status"] as? String, "completed")
        XCTAssertTrue(processed(pinned).isEmpty)

        let original = try Data(contentsOf: firstResult)
        try (original + Data([10])).write(to: firstResult, options: .atomic)
        let restored = try providerEvents(standalone)
        XCTAssertEqual(restored.last?["status"] as? String, "completed")
        XCTAssertTrue(processed(restored).isEmpty)
        XCTAssertEqual(try Data(contentsOf: firstResult), original)

        let another = try prepare()
        XCTAssertNotEqual(another.id, initial.id)
        let externalHits = try providerEvents(XCTUnwrap(another.sessions.first?.command))
        XCTAssertEqual(externalHits.last?["status"] as? String, "completed")
        XCTAssertTrue(processed(externalHits).isEmpty)

        let live = try store.prepare(media: media, documentID: "live",
                                     options: .init(engine: "parakeet-v3", diarization: false))
        let finished = try store.run(live.id, helper: URL(fileURLWithPath: provider))
        XCTAssertEqual(finished.state, .completed, finished.message ?? "")
        XCTAssertEqual(finished.sessions.flatMap(\.tracks).map(\.state), [.cached, .cached])
    }
}
