import Darwin
import Foundation
import XCTest
@testable import MPCutCore

final class TranscriptJobRunnerTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MPCut-runner-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        isolateRecognitionResults(in: folder)
        return folder
    }

    private func wave(in folder: URL, name: String = "source.wav", samples: UInt32 = 16_000) throws -> URL {
        let file = folder.appendingPathComponent(name)
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(samples * 2 + 36)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(samples * 2)
        data.append(Data(repeating: 0, count: Int(samples * 2)))
        try data.write(to: file)
        return file
    }

    private func helper(in folder: URL, script: String) throws -> URL {
        let file = folder.appendingPathComponent("helper")
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func testProviderDrainsFinalEventWithoutNewline() throws {
        let folder = try directory()
        let provider = try helper(in: folder, script: """
        #!/bin/sh
        printf '%s' '{"schema_version":1,"job_id":"job","fingerprint":"session","event":"session_finished","status":"completed"}'
        """)
        var events: [TranscriptProviderEvent] = []
        let response = try TranscriptProviderCommand(helper: provider, directory: folder).run([]) {
            events.append($0)
        }
        XCTAssertEqual(response.exitStatus, 0)
        XCTAssertEqual(events.map(\.event), ["session_finished"])
    }

    func testMissingSessionCapabilityPersistsFailure() throws {
        let folder = try directory()
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let job = try store.prepare(media: wave(in: folder), documentID: "one")
        let provider = try helper(in: folder, script: "#!/bin/sh\nprintf '{}\\n'\n")
        XCTAssertThrowsError(try store.run(job.id, helper: provider)) {
            XCTAssertEqual(($0 as? CutError)?.code, "transcript_capability_missing")
        }
        let failed = try store.status(job.id)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNil(failed.helperPID)
        XCTAssertNil(failed.ownerToken)
    }

    func testMissingModelLeavesJobRetryableWithoutLaunchingSession() throws {
        let folder = try directory()
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let job = try store.prepare(media: wave(in: folder), documentID: "one")
        let provider = try helper(in: folder, script: """
        #!/bin/sh
        case "$1" in
          capabilities)
            printf '%s\n' '{"version":"fixture","session_schema_version":1,"engines":[{"name":"qwen3","aliases":[],"included":true,"default_model":"fixture-model","diarization":false,"minimum_macos":"14.0","model_source":"hugging-face"}]}'
            ;;
          --cached-model) printf '[]\n' ;;
          *) touch unexpected-provider-launch; exit 1 ;;
        esac
        """)
        let result = try store.run(job.id, helper: provider)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.message?.contains("fixture-model") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            result.workingDirectory.appendingPathComponent("unexpected-provider-launch").path))
        XCTAssertEqual(try store.retry(job.id).state, .prepared)
    }

    func testStaleMediaDoesNotLaunchProvider() throws {
        let folder = try directory()
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let source = try wave(in: folder)
        let job = try store.prepare(media: source, documentID: "one")
        _ = try wave(in: folder, samples: 32_000)
        let result = try store.run(job.id, helper: folder.appendingPathComponent("missing-helper"), download: true)
        XCTAssertEqual(result.state, .stale)
        XCTAssertTrue(result.message?.contains("Media changed") == true)
        XCTAssertNil(result.ownerToken)
    }

    func testModelRevisionChangeMakesCompletionStale() throws {
        let folder = try directory()
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let job = try store.prepare(media: wave(in: folder), documentID: "one")
        let firstRevision = String(repeating: "a", count: 64)
        let replacement = String(repeating: "b", count: 64)
        let provider = try helper(in: folder, script: """
        #!/bin/sh
        case "$1" in
          capabilities)
            printf '%s\n' '{"version":"fixture","cache_revision":"provider","session_schema_version":1,"engines":[{"name":"qwen3","aliases":[],"included":true,"default_model":"fixture-model","diarization":false,"minimum_macos":"14.0","model_source":"hugging-face"}]}'
            ;;
          --cached-model)
            revision=\(firstRevision)
            if [ -f swapped-model ]; then revision=\(replacement); fi
            printf '[{"id":"fixture-model","cached":true,"path":"/unused","revision":"%s"},{"id":"Qwen/Qwen3-ForcedAligner-0.6B","cached":true,"path":"/unused","revision":"%s"}]\n' "$revision" "\(firstRevision)"
            ;;
          session) touch swapped-model ;;
        esac
        """)
        let result = try store.run(job.id, helper: provider)
        XCTAssertEqual(result.state, .stale)
        XCTAssertTrue(result.message?.contains("model changed") == true)
        XCTAssertNil(result.sessions.first?.tracks.first?.recognitionKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(result.sessions.first?.output.path)))
    }

    func testCancellationStopsHelperAndRetryRestages() throws {
        let folder = try directory()
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let job = try store.prepare(media: wave(in: folder), documentID: "one")
        let provider = try helper(in: folder, script: """
        #!/bin/sh
        /bin/sh -c 'trap "touch helper-child-terminated; exit" TERM; touch helper-child-ready; sleep 30' &
        wait
        """)
        let done = expectation(description: "runner exited")
        let started = expectation(description: "helper launched")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                let result = try store.run(job.id, helper: provider)
                XCTAssertEqual(result.state, .cancelled)
            } catch { XCTFail("Runner returned \(error)") }
        }
        var pid: Int32?
        let deadline = ContinuousClock.now + .seconds(5)
        while .now < deadline {
            if let child = try store.status(job.id).helperPID,
               FileManager.default.fileExists(atPath: job.workingDirectory.appendingPathComponent("helper-child-ready").path) {
                pid = child
                started.fulfill()
                break
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        wait(for: [started], timeout: 0.1)
        let competing = try store.run(job.id, helper: provider)
        XCTAssertEqual(competing.state, .running)
        XCTAssertEqual(competing.helperPID, pid)
        _ = try store.cancel(job.id)
        wait(for: [done], timeout: 5)
        if let pid { XCTAssertEqual(kill(pid, 0), -1) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.workingDirectory.appendingPathComponent("helper-child-terminated").path))
        let staged = try XCTUnwrap(job.sessions.first?.tracks.first?.audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let retried = try store.retry(job.id)
        XCTAssertEqual(retried.state, .prepared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testCancellingAnAbandonedRunRetiresStagedAudio() throws {
        let folder = try directory()
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let job = try store.prepare(media: wave(in: folder), documentID: "one")
        let audio = try XCTUnwrap(job.sessions.first?.tracks.first?.audio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        try store.update(job.id) {
            $0.state = .running
            $0.ownerToken = UUID()
            $0.ownerPID = Int32.max
        }
        let cancelled = try store.cancel(job.id)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertNil(cancelled.ownerToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testRealHelperResumeAndCrossProjectCache() throws {
        guard let path = ProcessInfo.processInfo.environment["MPCUT_TEST_TRANSCRIBERRR_HELPER"] else {
            throw XCTSkip("Set MPCUT_TEST_TRANSCRIBERRR_HELPER to a session-enabled batch helper with local models.")
        }
        let provider = URL(fileURLWithPath: path)
        let folder = try directory()
        let source = try wave(in: folder)
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let first = try store.prepare(media: source, documentID: "one")
        let completed = try store.run(first.id, helper: provider)
        XCTAssertEqual(completed.state, .completed, completed.message ?? "")
        XCTAssertEqual(completed.sessions.first?.tracks.first?.state, .recognized)
        let second = try store.prepare(media: source, documentID: "two")
        let cached = try store.run(second.id, helper: provider)
        XCTAssertEqual(cached.state, .completed, cached.message ?? "")
        XCTAssertEqual(cached.sessions.first?.tracks.first?.state, .cached)
        XCTAssertEqual(try store.verifiedOutputs(cached.id, media: source), cached.sessions.map(\.output))
        let retried = try store.retry(first.id)
        let replay = try store.run(retried.id, helper: provider)
        XCTAssertEqual(replay.state, .completed, replay.message ?? "")
        XCTAssertEqual(try store.verifiedOutputs(replay.id, media: source), completed.sessions.map(\.output))

        let stale = try store.prepare(media: source, documentID: "stale")
        _ = try wave(in: folder, samples: 32_000)
        XCTAssertEqual(try store.run(stale.id, helper: provider).state, .stale)
        let changed = try store.prepare(media: source, documentID: "three")
        let regenerated = try store.run(changed.id, helper: provider)
        XCTAssertEqual(regenerated.state, .completed, regenerated.message ?? "")
        XCTAssertEqual(regenerated.sessions.first?.tracks.first?.state, .recognized)
        XCTAssertNotEqual(regenerated.sessions.first?.tracks.first?.recognitionKey,
                          completed.sessions.first?.tracks.first?.recognitionKey)
    }

    func testRealHelperPartialRetryKeepsCompletedTrack() throws {
        guard let path = ProcessInfo.processInfo.environment["MPCUT_TEST_TRANSCRIBERRR_HELPER"] else {
            throw XCTSkip("Set MPCUT_TEST_TRANSCRIBERRR_HELPER to a session-enabled batch helper with local models.")
        }
        let folder = try directory()
        let damageList = folder.appendingPathComponent("damage-when-launched")
        let provider = try helper(in: folder, script: """
        #!/bin/sh
        if [ "$1" = session ] && [ -f \(shellQuote(damageList.path)) ]; then
          while IFS= read -r wav; do
            printf 'invalid PCM' > "$wav"
          done < \(shellQuote(damageList.path))
          rm \(shellQuote(damageList.path))
        fi
        exec \(shellQuote(path)) "$@"
        """)
        let front = try wave(in: folder, name: "front.wav")
        let recorder = try wave(in: folder, name: "recorder.wav", samples: 24_000)
        let project = CutProject.multicam(MulticamProject(referenceAngle: "front",
            range: .init(from: .zero, to: RationalTime(numerator: 1, denominator: 1)),
            angles: [.init(id: "front", file: front.path)],
            audioSources: [.init(id: "recorder", file: recorder.path)], audio: .none, switches: []))
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let options = TranscriptJobOptions(engine: "parakeet-v3", diarization: false)
        let prepared = try store.prepare(project: project, documentID: "partial", options: options)
        let inputs = try XCTUnwrap(prepared.sessions.first?.tracks)
        let firstTrack = try XCTUnwrap(inputs.first { $0.sourceID == "front" })
        let secondTrack = try XCTUnwrap(inputs.first { $0.sourceID == "recorder" })
        let firstResult = try XCTUnwrap(firstTrack.result)
        let secondWAV = try XCTUnwrap(secondTrack.audio)
        try Data((secondWAV.path + "\n").utf8).write(to: damageList)
        let partial = try store.run(prepared.id, helper: provider)
        XCTAssertEqual(partial.state, .partial, partial.message ?? "")
        XCTAssertEqual(partial.sessions.first?.tracks.first { $0.id == firstTrack.id }?.state, .recognized)
        XCTAssertEqual(partial.sessions.first?.tracks.first { $0.id == secondTrack.id }?.state, .failed)
        let acceptedStamp = try SourceIdentity(firstResult)

        let retry = try store.retry(prepared.id, project: project)
        let completed = try store.run(retry.id, helper: provider)
        XCTAssertEqual(completed.state, .completed, completed.message ?? "")
        XCTAssertEqual(try SourceIdentity(firstResult), acceptedStamp)
        XCTAssertEqual(try store.verifiedOutputs(completed.id, project: project), completed.sessions.map(\.output))

        guard case .multicam(var narrowed) = project else { return XCTFail("Expected a multicam project.") }
        narrowed.audioSources = []
        let reduced = CutProject.multicam(narrowed)
        let originalBytes = try Data(contentsOf: firstResult)
        try AnalysisSidecar.$readsEnabled.withValue(false) {
            let relocated = try store.retry(prepared.id, project: reduced)
            let carried = try XCTUnwrap(relocated.sessions.first?.tracks.first?.result)
            XCTAssertNotEqual(carried, firstResult)
            XCTAssertEqual(try Data(contentsOf: carried), originalBytes)
            let carriedStamp = try SourceIdentity(carried)
            let reconciled = try store.run(relocated.id, helper: provider)
            XCTAssertEqual(reconciled.state, .completed, reconciled.message ?? "")
            XCTAssertEqual(try SourceIdentity(carried), carriedStamp)
        }

        let restarted = try store.prepare(project: project, documentID: "all-failed", options: options,
                                          policy: .restart)
        let damagedPaths = restarted.sessions.flatMap(\.tracks).compactMap { $0.audio?.path }
        try Data((damagedPaths.joined(separator: "\n") + "\n").utf8).write(to: damageList)
        let failed = try store.run(restarted.id, helper: provider)
        XCTAssertEqual(failed.state, .failed, failed.message ?? "")
        XCTAssertTrue(failed.sessions.flatMap(\.tracks).allSatisfy { $0.state == .failed })
        XCTAssertTrue(failed.sessions.allSatisfy { !FileManager.default.fileExists(atPath: $0.output.path) })
        XCTAssertThrowsError(try store.verifiedOutputs(failed.id, project: project))
    }

    func testRealHelperMissingDiarizerKeepsIsolatedRecognition() throws {
        guard let path = ProcessInfo.processInfo.environment["MPCUT_TEST_TRANSCRIBERRR_HELPER"] else {
            throw XCTSkip("Set MPCUT_TEST_TRANSCRIBERRR_HELPER to a session-enabled batch helper with local models.")
        }
        let folder = try directory()
        let provider = try helper(in: folder, script: """
        #!/bin/zsh
        typeset -a arguments
        while (( $# )); do
          if [[ "$1" == --cached-model && "$2" == sortformer ]]; then
            shift 2
          else
            arguments+=("$1")
            shift
          fi
        done
        exec \(shellQuote(path)) "${arguments[@]}"
        """)
        let mic = try wave(in: folder, name: "mic.wav")
        let mix = try wave(in: folder, name: "mix.wav", samples: 24_000)
        let project = CutProject.multicam(MulticamProject(referenceAngle: "mic",
            range: .init(from: .zero, to: RationalTime(numerator: 1, denominator: 1)),
            angles: [.init(id: "mic", file: mic.path)],
            audioSources: [.init(id: "mix", file: mix.path)], audio: .none, switches: []))
        let inputs = try XCTUnwrap(TranscriptJobPlan.inventory(project: project).first?.tracks)
        let isolated = try XCTUnwrap(inputs.first { $0.sourceID == "mic" })
        let mixed = try XCTUnwrap(inputs.first { $0.sourceID == "mix" })
        let options = TranscriptJobOptions(diarization: true,
            trackOptions: [isolated.id: .init(role: "isolated_mic")])
        let store = TranscriptJobStore(directory: folder.appendingPathComponent("jobs"))
        let prepared = try store.prepare(project: project, documentID: "models", options: options)
        let result = try store.run(prepared.id, helper: provider)
        XCTAssertEqual(result.state, .partial, result.message ?? "")
        XCTAssertEqual(result.sessions.first?.tracks.first { $0.id == isolated.id }?.state, .recognized)
        XCTAssertEqual(result.sessions.first?.tracks.first { $0.id == mixed.id }?.state, .failed)
        XCTAssertTrue(result.sessions.first?.tracks.first { $0.id == mixed.id }?.message?.contains("sortformer") == true)
        let output = try XCTUnwrap(store.verifiedOutputs(result.id, project: project).first)
        let transcript = try TranscriptCodec.decode(Data(contentsOf: output), format: .json)
        XCTAssertEqual(transcript.tracks.first { $0.id == isolated.id }?.coverage, .recognized)
        XCTAssertTrue(transcript.words.isEmpty, "Recognized silence still makes the partial result usable.")
    }

}
