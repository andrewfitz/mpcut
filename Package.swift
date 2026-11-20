// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The bundle script supplies the pinned FFmpeg headers and libraries directly.
let bundledFFmpeg = ProcessInfo.processInfo.environment["MPCUT_BUNDLED_FFMPEG"] == "1"

let package = Package(
    name: "MPCut",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MPCutDesktop", targets: ["MPCutApp"]),
        .executable(name: "mpcut", targets: ["MPCutCLI"])
    ],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: bundledFFmpeg ? nil : "libavformat",
            providers: bundledFFmpeg ? nil : [.brew(["ffmpeg"])]
        ),
        .target(name: "PacketWriter", dependencies: ["CFFmpeg", "FFPreview"], linkerSettings: [.linkedLibrary("avcodec"), .linkedLibrary("avutil")]),
        .target(name: "MediaProbe", dependencies: ["CFFmpeg"]),
        .target(
            name: "FFPreview",
            dependencies: ["CFFmpeg"],
            linkerSettings: [
                .linkedLibrary("swresample"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"),
                .linkedFramework("CoreMedia"), .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"), .linkedFramework("CoreVideo")
            ]
        ),
        .target(name: "MPCutCore", dependencies: ["PacketWriter", "MediaProbe"]),
        .executableTarget(name: "MPCutCLI", dependencies: ["MPCutCore"]),
        .executableTarget(name: "MPCutApp", dependencies: ["MPCutCore", "FFPreview"]),
        .testTarget(name: "MPCutCoreTests", dependencies: ["MPCutCore"]),
        .testTarget(name: "MPCutAppTests", dependencies: ["MPCutApp"], resources: [.copy("Fixtures")])
    ]
)
