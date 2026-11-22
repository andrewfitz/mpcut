import AppKit
import Foundation

/// Final Cut owns its library database. It receives and supplies project snapshots
/// through its documented Open Document and File > Export XML interfaces.
public enum FCPLibraryInterchange {
    public static func read(_ url: URL, allowLoss: Bool, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> (CutProject, [String]) {
        try ProjectConverter.checkCancellation(cancelled)
        let library = url.standardizedFileURL
        guard try library.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CutError(code: "invalid_project", message: "Choose a Final Cut Pro library package.")
        }
        let app = try finalCut()
        try open(library, in: app)
        let path = try run("/usr/bin/osascript", ["-l", "JavaScript", "-e", """
            ObjC.import('AppKit')
            function run(argv) {
                const app = $.NSApplication.sharedApplication
                app.setActivationPolicy($.NSApplicationActivationPolicyAccessory)
                app.activateIgnoringOtherApps(true)
                const panel = $.NSOpenPanel.openPanel
                panel.title = 'Import one Final Cut project into MPCut'
                panel.message = 'In Final Cut Pro, select the project in ' + argv[0] +
                    ' and choose File > Export XML. Then choose the exported file here.'
                panel.allowedFileTypes = ['fcpxml', 'fcpxmld']
                panel.treatsFilePackagesAsDirectories = false
                if (panel.runModal != $.NSModalResponseOK) return ''
                return ObjC.unwrap(panel.URL.path)
            }
            """, library.lastPathComponent], cancelled: cancelled)
        guard !path.isEmpty else {
            throw CutError(code: "cancelled", message: "Final Cut Pro project selection was cancelled.")
        }
        let (project, warnings) = try FCPInterchange.read(URL(fileURLWithPath: path), allowLoss: allowLoss)
        return (project, warnings + ["Imported the selected Final Cut project snapshot at \(path). Other projects, events and library organization stay in the Final Cut library."])
    }

    public static func write(_ project: CutProject, relativeTo location: URL, to output: URL,
                             allowLoss: Bool, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> [String] {
        try ProjectConverter.checkCancellation(cancelled)
        let app = try finalCut()
        let destination = output.standardizedFileURL
        let manager = FileManager.default
        guard (try? manager.attributesOfItem(atPath: destination.path)) == nil else {
            throw CutError(code: "output_exists", message: "The destination already exists at \(destination.path).")
        }

        // Give FCP a unique library target so simultaneous exports cannot merge events.
        // Linked audio created by the interchange writer stays at its original path.
        let work = destination.deletingLastPathComponent()
            .appendingPathComponent("MPCut Final Cut \(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let library = work.appendingPathComponent(destination.lastPathComponent, isDirectory: false)
        let xml = library.deletingPathExtension().appendingPathExtension("fcpxml")
        var sentToHost = false
        do {
            var warnings = try FCPInterchange.write(project, relativeTo: location, to: xml, allowLoss: allowLoss, cancelled: cancelled)
            try setImportLibrary(library, in: xml)
            try ProjectConverter.checkCancellation(cancelled)
            try open(xml, in: app)
            sentToHost = true
            let confirmed = try run("/usr/bin/osascript", ["-e", """
                on run argv
                    activate
                    try
                        display dialog ("In Final Cut Pro, check the imported project and audio in " & item 1 of argv & ". Close that library with File > Close Library, then click Publish to move it to the requested destination.") with title "Export Final Cut Pro Library" buttons {"Cancel", "Publish"} default button "Publish" cancel button "Cancel"
                        return "publish"
                    on error number -128
                        return "cancel"
                    end try
                end run
                """, library.lastPathComponent], cancelled: cancelled)
            guard confirmed == "publish" else {
                throw CutError(code: "cancelled", message: "Final Cut library publication was cancelled.")
            }
            let attributes = try library.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isSymbolicLink != true, attributes.isDirectory == true,
                  !(try manager.contentsOfDirectory(atPath: library.path)).isEmpty else {
                throw CutError(code: "host_conversion_failed", message: "Final Cut did not create the requested library.")
            }
            try ProjectConverter.checkCancellation(cancelled)
            let error = publishExclusively(from: library, to: destination, isDirectory: true)
            guard error == 0 else {
                throw CutError(code: error == EEXIST ? "output_exists" : "write_failed",
                               message: "Could not publish \(destination.path): \(String(cString: strerror(error)))")
            }
            try? manager.removeItem(at: xml)
            if rmdir(work.path) != 0 {
                warnings.append("Keep the linked Final Cut project media in \(work.path).")
            }
            return warnings
        } catch {
            if sentToHost {
                let code = (error as? CutError)?.code ?? "host_conversion_failed"
                throw CutError(code: code, message: "\(error.localizedDescription) The Final Cut working files are in \(work.path).")
            }
            try? manager.removeItem(at: work)
            throw error
        }
    }

    private static func setImportLibrary(_ library: URL, in xml: URL) throws {
        let doc = try XMLDocument(contentsOf: xml, options: [.nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(), root.name == "fcpxml" else {
            throw CutError(code: "invalid_project", message: "Could not prepare the Final Cut import document.")
        }
        let options = XMLElement(name: "import-options")
        for (key, value) in [("library location", library.absoluteString), ("copy assets", "0")] {
            let option = XMLElement(name: "option")
            option.setAttributesWith(["key": key, "value": value])
            options.addChild(option)
        }
        root.insertChild(options, at: 0)
        try doc.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement]).write(to: xml, options: .atomic)
    }

    private static func finalCut() throws -> URL {
        for id in ["com.apple.FinalCut", "com.apple.FinalCutApp"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return app }
        }
        throw CutError(code: "host_unavailable",
                       message: "Install Final Cut Pro to convert a .fcpbundle. For conversion without the app, use a project exported as .fcpxml or .fcpxmld.")
    }

    private static func open(_ document: URL, in app: URL) throws {
        _ = try run("/usr/bin/open", ["-a", app.path, document.path])
    }

    static func run(_ executable: String, _ arguments: [String], cancelled: @escaping @Sendable () -> Bool = { false }) throws -> String {
        try ProjectConverter.checkCancellation(cancelled)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        // Our helpers return a single path or status. Poll while their UI is open
        // so cancelling an import or quitting MPCut can dismiss the chooser.
        while process.isRunning {
            if cancelled() {
                process.terminate()
                let deadline = ContinuousClock.now + .seconds(1)
                while process.isRunning && ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw CutError(code: "cancelled", message: "Final Cut Pro interaction was cancelled.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CutError(code: "host_conversion_failed",
                           message: "The Final Cut Pro interaction failed. Use File > Export XML for a project snapshot.")
        }
        var result = String(decoding: data, as: UTF8.self)
        if result.last == "\n" { result.removeLast() }
        return result
    }
}
