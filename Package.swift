// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The bundle script supplies the pinned FFmpeg headers and libraries directly.
let bundledFFmpeg = ProcessInfo.processInfo.environment["MPCUT_BUNDLED_FFMPEG"] == "1"

// The independently released TileTrail C ABI is optional for normal builds.
let tileTrailPrefix = ProcessInfo.processInfo.environment["MPCUT_TILETRAIL_PREFIX"].flatMap {
    $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL
}
let tileTrailArchive = tileTrailPrefix?.appendingPathComponent("lib/libtiletrail.a").path
// The explicit Clang module scanner also loads CTileTrail when compiling
// Swift targets that import MPCutCore.
let tileTrailSwiftSettings: [SwiftSetting] = tileTrailPrefix.map {
    [.unsafeFlags(["-Xcc", "-I" + $0.appendingPathComponent("include").path])]
} ?? []
if let prefix = tileTrailPrefix, let archive = tileTrailArchive {
    precondition(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("include/tiletrail.h").path)
        && FileManager.default.fileExists(atPath: archive),
        "MPCUT_TILETRAIL_PREFIX must contain include/tiletrail.h and lib/libtiletrail.a.")
}

let package = Package(
    name: "MPCut",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MPCutDesktop", targets: ["MPCutApp"]),
        .executable(name: "mpcut", targets: ["MPCutCLI"])
    ],
    targets: (tileTrailPrefix == nil ? [] : [.systemLibrary(name: "CTileTrail")]) + [
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: bundledFFmpeg ? nil : "libavformat",
            providers: bundledFFmpeg ? nil : [.brew(["ffmpeg"])]
        ),
        .target(name: "PacketWriter", dependencies: ["CFFmpeg", "FFPreview", "MediaProbe"], linkerSettings: [.linkedLibrary("avcodec"), .linkedLibrary("avutil")]),
        .target(name: "MediaProbe", dependencies: ["CFFmpeg"], linkerSettings: [
            .linkedFramework("Accelerate"), .linkedLibrary("swscale"), .linkedLibrary("swresample"), .linkedFramework("CoreVideo"),
            .linkedFramework("CoreMedia"), .linkedFramework("AVFoundation"), .linkedFramework("VideoToolbox")
        ]),
        .target(
            name: "FFPreview",
            dependencies: ["CFFmpeg"],
            linkerSettings: [
                .linkedLibrary("swresample"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"),
                .linkedFramework("CoreMedia"), .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"), .linkedFramework("CoreVideo")
            ]
        ),
        .target(
            name: "MPCutCore",
            dependencies: ["PacketWriter", "MediaProbe"] + (tileTrailPrefix == nil ? [] : ["CTileTrail"]),
            resources: [.copy("Gap.png")],
            swiftSettings: tileTrailSwiftSettings,
            linkerSettings: tileTrailArchive.map {
                [.unsafeFlags([$0]), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
                 .linkedFramework("Foundation"), .linkedFramework("CoreFoundation"),
                 .linkedFramework("CoreGraphics"), .linkedLibrary("objc"), .linkedLibrary("iconv")]
            } ?? []
        ),
        .executableTarget(name: "MPCutCLI", dependencies: ["MPCutCore"], swiftSettings: tileTrailSwiftSettings),
        .executableTarget(name: "MPCutApp", dependencies: ["MPCutCore", "FFPreview"],
                          resources: [.copy("MCPResources")], swiftSettings: tileTrailSwiftSettings),
        .testTarget(name: "MPCutCoreTests", dependencies: ["MPCutCore"], swiftSettings: tileTrailSwiftSettings),
        // Sets MPCUT_MUTED=1 as the app test bundle loads, so in-process tests are never heard.
        .target(name: "MPCutTestSupport", path: "Tests/MPCutTestSupport"),
        .testTarget(name: "MPCutAppTests", dependencies: ["MPCutApp", "MPCutTestSupport"],
                    resources: [.copy("Fixtures")], swiftSettings: tileTrailSwiftSettings)
    ]
)
