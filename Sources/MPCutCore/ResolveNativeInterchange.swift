import AppKit
import Darwin
import Foundation

/// Resolve owns its native archive formats. The host bridge uses a private library
/// project for each operation and publishes only archives it has reopened.
public enum ResolveNativeInterchange {
    public static func write(_ project: CutProject, relativeTo location: URL, to output: URL,
                             allowLoss: Bool, auxiliaryOutput: ((URL) -> Void)? = nil,
                             cancelled: @escaping @Sendable () -> Bool = { false }) throws -> [String] {
        try ProjectConverter.checkCancellation(cancelled)
        try project.validateDestination(output, relativeTo: location)
        let ext = try archiveExtension(output)
        let conversion = try ProjectConverter.prepareForInterchange(project, for: "DaVinci Resolve .\(ext)", allowLoss: allowLoss)
        let project = conversion.project
        let files = FileManager.default
        guard !files.fileExists(atPath: output.path) else {
            throw CutError(code: "output_exists", message: "The destination already exists at \(output.path).")
        }
        var warnings = conversion.warnings
        if case .sequence(let clips) = project,
           clips.contains(where: { $0.audioTrack != nil || $0.originalFile != nil || !$0.replacementNames.isEmpty }) {
            let message = "Resolve links each playable source with its replacement audio. Its archive omits MPCut’s original recording references, replacement track names and preview-track choices."
            guard allowLoss else { throw CutError(code: "conversion_loss", message: message) }
            warnings.append(message)
        }
        let token = UUID().uuidString
        let parent = output.deletingLastPathComponent()
        let media = parent.appendingPathComponent("\(output.deletingPathExtension().lastPathComponent) Media \(token)")
        try files.createDirectory(at: media, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        var published = false
        defer {
            if published { _ = rmdir(media.path) } else { try? files.removeItem(at: media) }
        }
        let xml = media.appendingPathComponent(output.deletingPathExtension().lastPathComponent).appendingPathExtension("fcpxml")
        defer { try? files.removeItem(at: xml) }
        warnings += try ResolveExport.writeFCP(project, relativeTo: location, to: xml, package: nil,
                                                  allowLoss: allowLoss, isolateSequenceAudio: true,
                                                  preserveMulticamEditing: false, preserveSequenceMetadata: false,
                                                  cancelled: cancelled)
        let helper = try host()
        let staged = media.appendingPathComponent(".mpcut-\(token).\(ext)")
        defer { try? files.removeItem(at: staged) }
        try ProjectConverter.checkCancellation(cancelled)
        let layoutReport = media.appendingPathComponent("layout-\(token).tsv")
        try run(helper, operation: "write", native: staged, xml: xml, ext: ext, report: layoutReport, cancelled: cancelled)
        warnings += try ResolveTimelineGeometry.verify(xml: xml, report: layoutReport, allowLoss: allowLoss)
        try files.removeItem(at: layoutReport)
        guard chmod(staged.path, try publicationPermissions(0o666)) == 0 else {
            throw CutError(code: "resolve_publish_failed", message: "Could not prepare permissions for the Resolve archive.")
        }
        try ProjectConverter.checkCancellation(cancelled)
        let result = publishExclusively(from: staged, to: output)
        guard result == 0 else {
            throw CutError(code: "resolve_publish_failed", message: "Could not publish \(output.path): \(String(cString: strerror(result))).")
        }
        published = true
        if (try? files.contentsOfDirectory(atPath: media.path).count) ?? 0 > 1 {
            warnings.append("Keep the generated source media in \(media.path) alongside this Resolve archive.")
            auxiliaryOutput?(media)
        }
        return warnings
    }

    public static func read(_ url: URL, allowLoss: Bool,
                            cancelled: @escaping @Sendable () -> Bool = { false }) throws -> (CutProject, [String]) {
        let imported = try readDocument(url, allowLoss: allowLoss, cancelled: cancelled)
        return (imported.project, imported.warnings)
    }

    package static func readDocument(_ url: URL, allowLoss: Bool,
                                     cancelled: @escaping @Sendable () -> Bool) throws
        -> (project: CutProject, warnings: [String], mediaSnapshot: ProjectMediaSnapshot) {
        try ProjectConverter.checkCancellation(cancelled)
        let ext = try archiveExtension(url)
        let nativeWarning = "Resolve exports timeline edits through FCPXML. Grades, Fusion compositions, Fairlight processing, render settings and Media Pool organization cannot be verified or retained in .cut."
        guard allowLoss else { throw CutError(code: "conversion_loss", message: nativeWarning) }
        let helper = try host()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = dir.appendingPathComponent("Timeline.fcpxmld")
        try run(helper, operation: "read", native: url, xml: xml, ext: ext, cancelled: cancelled)
        let imported = try FCPInterchange.readDocument(xml, allowLoss: allowLoss)
        let paths = imported.project.mediaPaths.map(\.1)
        let temporaryPrefix = dir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard !paths.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(temporaryPrefix) }) else {
            throw CutError(code: "resolve_embedded_media", message: "This timeline references embedded temporary media. Relink those clips to permanent source files in Resolve and export the archive again.")
        }
        return (imported.project, [nativeWarning] + imported.warnings, imported.mediaSnapshot)
    }

    private static func archiveExtension(_ url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard ["drp", "drt"].contains(ext) else {
            throw CutError(code: "invalid_resolve_format", message: "A Resolve native archive uses .drp or .drt.")
        }
        return ext
    }

    private static func host() throws -> URL {
        let bundle = "com.blackmagic-design.DaVinciResolve"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.bundleURL else {
            throw CutError(code: "resolve_unavailable", message: "Open DaVinci Resolve and enable local external scripting to convert a native archive.")
        }
        return app.appendingPathComponent("Contents/Libraries/Fusion/fuscript")
    }

    /// Both the native bridge and direct timeline handoff target Resolve's active project.
    static func withHostLock<T>(_ work: () throws -> T) throws -> T {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("mpcut-resolve-interchange.lock")
        let descriptor = open(lock.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw CutError(code: "resolve_lock_failed", message: "Could not lock the Resolve bridge.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw CutError(code: "resolve_busy", message: "Another MPCut conversion is using Resolve.")
        }

        return try work()
    }

    private static func run(_ helper: URL, operation: String, native: URL, xml: URL, ext: String, report: URL? = nil,
                            cancelled: () -> Bool) throws {
        try withHostLock {
            try runLocked(helper, operation: operation, native: native, xml: xml, ext: ext, layout: report, cancelled: cancelled)
        }
    }

    private static func runLocked(_ helper: URL, operation: String, native: URL, xml: URL, ext: String, layout: URL?,
                                  cancelled: () -> Bool) throws {
        try ProjectConverter.checkCancellation(cancelled)
        let files = FileManager.default
        let id = UUID().uuidString
        let report = files.temporaryDirectory.appendingPathComponent("mpcut-resolve-\(id).log")
        guard files.createFile(atPath: report.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CutError(code: "resolve_log_failed", message: "Could not open the Resolve conversion log.")
        }
        defer { try? files.removeItem(at: report) }
        let cancellation = report.appendingPathExtension("cancel")
        defer { try? files.removeItem(at: cancellation) }
        let handle = try FileHandle(forWritingTo: report)
        defer { try? handle.close() }
        let task = Process()
        task.executableURL = helper
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = handle
        task.standardError = handle
        task.environment = ProcessInfo.processInfo.environment.merging([
            "MPCUT_OPERATION": operation, "MPCUT_NATIVE": native.path, "MPCUT_XML": xml.path,
            "MPCUT_LAYOUT": layout?.path ?? "", "MPCUT_EXT": ext, "MPCUT_TEMP": "MPCut \(id)",
            "MPCUT_CANCEL": cancellation.path
        ]) { _, new in new }
        task.arguments = ["-l", "lua", "-x", bridge]
        try task.run()
        let deadline = ContinuousClock.now + .seconds(180)
        var cancellationSignalled = false
        while task.isRunning && ContinuousClock.now < deadline {
            // Let Lua restore the original project and remove its temporary ones.
            if !cancellationSignalled && cancelled() {
                cancellationSignalled = files.createFile(atPath: cancellation.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
            task.waitUntilExit()
            if cancelled() {
                throw CutError(code: "cancelled", message: "Resolve did not finish cancelling. Check for a host dialog and the temporary project MPCut \(id) in the Project Manager.")
            }
            throw CutError(code: "resolve_timeout", message: "Resolve timed out. Check for a host dialog and the temporary project MPCut \(id) in the Project Manager.")
        }
        let log = try String(contentsOf: report, encoding: .utf8)
        let detail = log.components(separatedBy: "MPCUT_NATIVE_ERROR ").dropFirst().last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cancelled() { throw CutError(code: "cancelled", message: detail ?? "Project conversion cancelled.") }
        guard task.terminationStatus == 0, log.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).last == "MPCUT_NATIVE_OK",
              !log.contains("MPCUT_NATIVE_ERROR ") else {
            throw CutError(code: "resolve_conversion_failed", message: detail ?? "Resolve did not respond. Enable local external scripting in Resolve's System preferences.")
        }
    }

    private static let bridge = ResolveTimelineGeometry.reportFunction + "\n" + #"""
    local r = Resolve()
    local pm = r and r:GetProjectManager()
    local function fail(s) error(s, 0) end
    local function checkCancelled()
        local marker = io.open(os.getenv("MPCUT_CANCEL"), "r")
        if marker then marker:close(); fail("Project conversion cancelled.") end
    end
    if not pm then print("MPCUT_NATIVE_ERROR Could not connect to Resolve.") return end
    local name, file, xml = os.getenv("MPCUT_TEMP"), os.getenv("MPCUT_NATIVE"), os.getenv("MPCUT_XML")
    local projectFile = os.getenv("MPCUT_EXT") == "drp"
    local original = pm:GetCurrentProject()
    local originalName = original and original:GetName()
    local originalID = original and original:GetUniqueId()
    local page = r:GetCurrentPage()
    local managed = {}
    local folder, db = pm:GetCurrentFolder(), pm:GetCurrentDatabase()
    local function checkLibrary()
        local current = pm:GetCurrentDatabase()
        if pm:GetCurrentFolder() ~= folder or db.DbName ~= current.DbName or db.DbType ~= current.DbType or db.IpAddress ~= current.IpAddress then
            fail("The active Resolve library or folder changed. Check its Project Manager for " .. name .. ".")
        end
    end
    local function active(p)
        checkLibrary()
        checkCancelled()
        local current = pm:GetCurrentProject()
        assert(current and current:GetUniqueId() == p:GetUniqueId() and current:GetName() == p:GetName(), "Resolve switched projects during conversion.")
    end
    local function exists(n)
        for _,v in ipairs(pm:GetProjectListInCurrentFolder() or {}) do if v == n then return true end end
        return false
    end
    local function available(n)
        checkLibrary()
        checkCancelled()
        if exists(n) then fail("Temporary project already exists.") end
    end
    local function record(n,p)
        assert(p:GetName()==n, "The temporary Resolve project has an unexpected name.")
        managed[n] = p:GetUniqueId()
        active(p)
        return p
    end
    local function selectTimeline(p)
        local count = p:GetTimelineCount()
        if count ~= 1 then
            fail("This Resolve project contains " .. count .. " timelines. Export the desired timeline as a .drt in Resolve.")
        end
        return assert(p:GetTimelineByIndex(1))
    end
    local function importNative(n)
        available(n)
        if projectFile then
            assert(pm:ImportProject(file, n), "Resolve could not import the .drp.")
            -- The archive is already in the library even if Resolve fails to open it.
            managed[n] = false
            checkCancelled()
            local p = assert(pm:LoadProject(n), "Resolve could not load the imported project.")
            record(n,p)
            return p, selectTimeline(p)
        end
        local p = assert(pm:CreateProject(n), "Resolve could not create a temporary project.")
        record(n,p)
        local t = assert(p:GetMediaPool():ImportTimelineFromFile(file, {importSourceClips=true}), "Resolve could not import the .drt.")
        return p, t
    end
    local function layout(t)
        local result = {t:GetSetting("timelineFrameRate"),t:GetStartFrame(),t:GetEndFrame()}
        for _,kind in ipairs({"video","audio","subtitle"}) do
            checkCancelled()
            table.insert(result,kind)
            table.insert(result,t:GetTrackCount(kind))
            for i=1,t:GetTrackCount(kind) do
                table.insert(result,i)
                for _,item in ipairs(t:GetItemListInTrack(kind,i) or {}) do
                    local source = item:GetMediaPoolItem()
                    table.insert(result,item:GetName())
                    table.insert(result,item:GetStart(true))
                    table.insert(result,item:GetEnd(true))
                    table.insert(result,item:GetLeftOffset(true))
                    table.insert(result,item:GetSourceStartFrame())
                    table.insert(result,item:GetSourceEndFrame())
                    table.insert(result,source and source:GetClipProperty("File Path") or "")
                    table.insert(result,source and source:GetClipProperty("Type") or "")
                end
            end
        end
        return table.concat(result,"\n")
    end
    -- Resolve starts in an unsaved project. While it is still empty there is nothing
    -- to lose or to reopen, so only an unsaved project with content blocks a conversion.
    if original and not exists(originalName) then
        local root = original:GetMediaPool():GetRootFolder()
        if original:GetTimelineCount() == 0 and #(root:GetClipList() or {}) == 0
            and #(root:GetSubFolderList() or {}) == 0 then
            originalName, originalID = nil, nil
        end
    end
    local ok, reason = pcall(function()
        checkCancelled()
        if originalName and not exists(originalName) then
            fail("Save or close the current unnamed Resolve project before converting a native archive.")
        end
        if os.getenv("MPCUT_OPERATION") == "read" then
            local p,t = importNative(name)
            checkCancelled()
            assert(t:Export(xml,r.EXPORT_FCPXML_1_10), "Resolve could not export the timeline to FCPXML.")
        else
            available(name)
            local p = assert(pm:CreateProject(name), "Resolve could not create a temporary project.")
            record(name,p)
            local t = assert(p:GetMediaPool():ImportTimelineFromFile(xml,{importSourceClips=true}), "Resolve declined the timeline.")
            local expected = layout(t)
            active(p)
            if projectFile then
                assert(pm:SaveProject(), "Resolve could not save the temporary project.")
                checkCancelled()
                assert(pm:ExportProject(name,file,false), "Resolve could not write the .drp.")
            else
                assert(t:Export(file,r.EXPORT_DRT), "Resolve could not write the .drt.")
            end
            active(p)
            local reopened,check = importNative(name .. " Verify")
            checkCancelled()
            writeLayout(check)
            assert(layout(check) == expected, "The reopened Resolve archive changed the timeline tracks, cuts, or source ranges.")
        end
    end)
    local restored, cleanup = pcall(function()
        if not next(managed) then return end
        checkLibrary()
        local current = pm:GetCurrentProject()
        if current and (current:GetUniqueId() ~= originalID or current:GetName() ~= originalName) then
            local mine = managed[current:GetName()] == current:GetUniqueId()
            if not mine then fail("Resolve switched projects during conversion. Check its Project Manager for " .. name .. ".") end
            assert(pm:CloseProject(current), "Resolve could not close its temporary project.")
        end
        if originalName then
            current = pm:GetCurrentProject()
            if not current or current:GetUniqueId() ~= originalID or current:GetName() ~= originalName then
                local p = pm:LoadProject(originalName)
                assert(p and p:GetUniqueId() == originalID, "Reopen your previous Resolve project: " .. originalName)
            end
            if page then r:OpenPage(page) end
        end
        for n,id in pairs(managed) do
            checkLibrary()
            if exists(n) then assert(pm:DeleteProject(n), "Remove the temporary Resolve project: " .. n) end
        end
    end)
    if not ok or not restored then
        print("MPCUT_NATIVE_ERROR " .. (not ok and tostring(reason) or "") .. (not restored and " " .. tostring(cleanup) or ""))
    else print("MPCUT_NATIVE_OK") end
    """#
}
