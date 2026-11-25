import AppKit
import MPCutCore

/// The engines a Transcriberrr helper offers, read from its `capabilities` answer.
struct TranscriptEngineCatalog: Decodable, Equatable {
    struct Engine: Decodable, Identifiable, Equatable {
        let name: String
        var aliases: [String]? = nil
        let included: Bool
        let helper_present: Bool?
        let default_model: String
        let minimum_macos: String
        let diarization: Bool
        let diarization_speaker_limit: Int?
        let estimated_realtime_factor: Double?
        var id: String { name }

        var title: String { TranscriptEngineCatalog.title(name) }

        /// Why this engine cannot run on this Mac, or nil when it can.
        var unavailableReason: String? {
            guard included else { return "This Transcriberrr does not include \(title)." }
            guard helper_present != false else { return "\(title) is not installed in Transcriberrr." }
            let version = minimum_macos.split(separator: ".").compactMap { Int($0) }
            guard let major = version.first else { return "\(title) names no macOS version it runs on." }
            let supported = ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(
                majorVersion: major, minorVersion: version.dropFirst().first ?? 0,
                patchVersion: version.dropFirst(2).first ?? 0
            ))
            return supported ? nil : "\(title) requires macOS \(minimum_macos) or later."
        }

        var available: Bool { unavailableReason == nil }

        func answers(to name: String) -> Bool { self.name == name || aliases?.contains(name) == true }
    }

    struct Automation: Decodable, Equatable {
        let plan: String?
        let zoom_iso_inventory: [String]?
    }

    var version: String? = nil
    let automation: Automation?
    let engines: [Engine]

    static func read(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    static func title(_ name: String) -> String {
        switch name {
        case "qwen3": "Qwen3"
        case "parakeet-v3": "Parakeet v3"
        case "apple-native": "Apple Speech"
        default: name
        }
    }

    /// The engine a job starts with, and why it is not the preferred one.
    struct Choice: Equatable {
        /// A named engine, or nil when no engine can run.
        let engine: String?
        /// Set when a preferred engine is unavailable. The preference itself is kept.
        let issue: String?
    }

    /// Automatic: Qwen3, then the first available engine.
    var automatic: String? {
        engines.first(where: { $0.available && $0.name == "qwen3" })?.name ?? engines.first(where: \.available)?.name
    }

    func engine(named name: String) -> Engine? { engines.first { $0.answers(to: name) } }

    /// Why a preferred engine cannot be used, or nil when it can. Empty is Automatic and always usable.
    func unavailableReason(forPreferred name: String) -> String? {
        guard !name.isEmpty else { return nil }
        guard let engine = engine(named: name) else {
            return "The installed Transcriberrr does not offer ‘\(name)’."
        }
        return engine.unavailableReason
    }

    /// Resolves Settings → Transcripts → Preferred engine to a named engine. Automatic, and a
    /// preferred engine that cannot run here, fall back to Qwen3, then the first available engine.
    func resolve(preferred: String) -> Choice {
        if preferred.isEmpty { return .init(engine: automatic, issue: nil) }
        if let engine = engine(named: preferred), engine.available { return .init(engine: engine.name, issue: nil) }
        return .init(engine: automatic, issue: unavailableReason(forPreferred: preferred))
    }
}

/// Transcriberrr's state for the Settings page, which works with no project open. It asks the
/// helper only when told to, so opening Settings in a test host starts nothing.
@MainActor
final class TranscriberrrStatus: ObservableObject {
    enum State: Equatable {
        case unchecked
        case checking
        case ready(helper: URL, catalog: TranscriptEngineCatalog)
        case failed(String)
    }

    @Published private(set) var state = State.unchecked
    private let locate: (String) throws -> URL
    private let probe: @Sendable (URL) throws -> Data
    private var task: Task<Void, Never>?

    init(locate: @escaping (String) throws -> URL = { try TranscriptJobStore.helperURL(chosen: $0) },
         probe: @escaping @Sendable (URL) throws -> Data = { try TranscriptJobStore.capabilities(helper: $0) }) {
        self.locate = locate
        self.probe = probe
    }

    /// Only a real app checks on its own. A test host or a command-line run waits for Check.
    static var checksAutomatically: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier?.isEmpty == false
    }

    var catalog: TranscriptEngineCatalog? {
        if case .ready(_, let catalog) = state { return catalog }
        return nil
    }

    func check(helperPath: String) {
        task?.cancel()
        let helper: URL
        do {
            helper = try locate(helperPath)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .checking
        let probe = probe
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try TranscriptEngineCatalog.read(probe(helper)) }
            }.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let catalog): state = .ready(helper: helper, catalog: catalog)
            case .failure(let error): state = .failed(error.localizedDescription)
            }
        }
    }

    func waitForCheck() async { await task?.value }

    /// The Transcriberrr app to open: the one holding the helper, or the installed one.
    static func application(helper: URL?) -> URL? {
        if let helper {
            let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app" { return app }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.transcriberrr.app")
    }
}
