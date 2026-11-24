import Foundation

enum InterchangeMediaPreflight {
    static func require(_ paths: [String], relativeTo location: URL) throws {
        let directory = ProjectFile.directory(of: location)
        let urls = Set(paths).map { path in
            let absolutePath = path.hasPrefix("/") ? path :
                directory.path + "/" + path
            let approximateURL = URL(fileURLWithPath: absolutePath, isDirectory: false)
            guard !ProjectMediaVolume.isChecking(approximateURL) else { return approximateURL }
            return ProjectFile.sourceURL(file: path, in: directory)
        }
        try require(urls)
    }

    static func require(_ urls: [URL]) throws {
        let unavailable = Set(urls).compactMap { url -> String? in
            guard !ProjectMediaVolume.isChecking(url), !url.path.contains("\0"),
                  !url.path.split(separator: "/").contains("..") else { return url.path }
            return (try? SourceIdentity(url)) == nil ? url.path : nil
        }
        guard !unavailable.isEmpty else { return }
        let paths = Set(unavailable).sorted().joined(separator: "\n")
        throw CutError(code: "missing_source", message: "Relink required media in Project Media before exporting:\n" + paths)
    }
}
