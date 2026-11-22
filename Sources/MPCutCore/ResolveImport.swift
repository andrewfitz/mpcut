import AppKit
import Darwin
import Foundation

extension ResolveExport {
    /// Add a new timeline to Resolve's open project. The XML survives a failed handoff.
    public static func openInResolve(_ url: URL, cancelled: (@Sendable () -> Bool)? = nil) throws {
        let bundle = "com.blackmagic-design.DaVinciResolve"
        try checkHandoffCancellation(url, cancelled)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            throw importFailure(url, "DaVinci Resolve could not be located.")
        }
        try importTimeline(url, helper: app.appendingPathComponent("Contents/Libraries/Fusion/fuscript"),
                           cancelled: cancelled)
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate()
    }

    private static func importFailure(_ url: URL, _ reason: String) -> CutError {
        CutError(code: "resolve_import_failed", message: "Saved \(url.path). \(reason) You can also use File → Import → Timeline in Resolve.")
    }

    private static func checkHandoffCancellation(_ url: URL, _ cancelled: (@Sendable () -> Bool)?) throws {
        if cancelled?() == true {
            throw CutError(code: "cancelled", message: "Saved \(url.path). The Resolve handoff was cancelled.")
        }
    }

    static func importTimeline(_ url: URL, helper: URL, timeout: Duration = .seconds(60),
                               cancelled: (@Sendable () -> Bool)? = nil) throws {
        try checkHandoffCancellation(url, cancelled)
        try ResolveNativeInterchange.withHostLock {
            try deliverTimeline(url, helper: helper, timeout: timeout, cancelled: cancelled)
        }
    }

    private static func deliverTimeline(_ url: URL, helper: URL, timeout: Duration,
                                        cancelled: (@Sendable () -> Bool)?) throws {
        let document = try FCPInterchange.loadDocument(url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let layout = folder.appendingPathComponent("layout.tsv")
        let process = Process()
        process.executableURL = helper
        process.standardInput = FileHandle.nullDevice
        // User-controlled names and paths travel as data, outside the Lua program.
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MPCUT_TIMELINE": url.path, "MPCUT_NAME": url.deletingPathExtension().lastPathComponent,
            "MPCUT_LAYOUT": layout.path
        ]) { _, new in new }
        process.arguments = ["-l", "lua", "-x", ResolveTimelineGeometry.reportFunction + "\n" + """
            local r = Resolve()
            local p = r and r:GetProjectManager():GetCurrentProject()
            if not p then return end
            local base = os.getenv("MPCUT_NAME")
            local names = {}
            for i=1,p:GetTimelineCount() do names[p:GetTimelineByIndex(i):GetName()] = true end
            local n, name = 2, base
            while names[name] do name = base .. " (" .. n .. ")" n = n+1 end
            local current = r:GetProjectManager():GetCurrentProject()
            if not current or current:GetUniqueId() ~= p:GetUniqueId() then print("MPCUT_PROJECT_CHANGED") return end
            local t = p:GetMediaPool():ImportTimelineFromFile(os.getenv("MPCUT_TIMELINE"), {timelineName=name, importSourceClips=true})
            if not t then print("MPCUT_REJECTED") return end
            if t:GetName() ~= name then t:SetName(name) end
            if p:SetCurrentTimeline(t) then
                r:OpenPage("edit")
                if pcall(writeLayout, t) then print("MPCUT_IMPORTED") else print("MPCUT_NO_LAYOUT") end
            else
                print("MPCUT_ADDED")
            end
            """]
        let pipe = Pipe()
        process.standardOutput = pipe.fileHandleForWriting
        process.standardError = pipe.fileHandleForWriting
        do { try process.run() } catch { throw importFailure(url, error.localizedDescription) }
        try? pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        let deadline = ContinuousClock.now + timeout
        var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 8192)
        var response = Data()
        do {
            while descriptor.fd >= 0 || process.isRunning {
                try checkHandoffCancellation(url, cancelled)
                guard ContinuousClock.now < deadline else {
                    throw importFailure(url, "Timed out waiting for Resolve. Check the current project's timelines.")
                }
                let ready = poll(&descriptor, 1, 50)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { throw importFailure(url, "Could not read the Resolve response.") }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor.fd, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw importFailure(url, "Could not read the Resolve response.") }
                if count == 0 { descriptor.fd = -1 }
                response.append(contentsOf: buffer.prefix(count))
                if response.count > 16384 { response = Data(response.suffix(8192)) }
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        let report = String(decoding: response, as: UTF8.self)
        let status = report.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces)
        if status == "MPCUT_NO_LAYOUT" {
            throw CutError(code: "resolve_layout_failed", message: "Resolve added the timeline but could not verify its layout. The XML is saved at \(url.path).")
        }
        if status == "MPCUT_ADDED" {
            throw CutError(code: "resolve_timeline_added", message: "Resolve added the timeline but could not select it. Open it from the Media Pool. The XML is saved at \(url.path).")
        }
        if status == "MPCUT_PROJECT_CHANGED" {
            throw importFailure(url, "The active Resolve project changed before the import.")
        }
        if status == "MPCUT_REJECTED" {
            throw importFailure(url, "Resolve declined the timeline. Check the Resolve import log and source media availability.")
        }
        guard process.terminationStatus == 0, status == "MPCUT_IMPORTED" else {
            throw importFailure(url, "Open a Resolve project and enable local external scripting in Resolve's System preferences.")
        }
        do {
            _ = try ResolveTimelineGeometry.verify(document: document, report: layout, allowLoss: false)
        } catch {
            throw CutError(code: "resolve_timeline_unverified",
                           message: "Resolve added the timeline to your current project. \(error.localizedDescription) The XML is saved at \(url.path).")
        }
    }
}
