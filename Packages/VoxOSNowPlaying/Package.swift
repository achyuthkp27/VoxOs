// swift-tools-version:5.9
import PackageDescription

// VoxOS's reader for what MediaRemote knows beyond the track: the queue that follows it and the
// audio format it plays in. A dynamic library, because it is loaded into /usr/bin/perl and run
// there (see Resources/now-playing.pl).
let package = Package(
    name: "VoxOSNowPlaying",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoxOSNowPlaying", type: .dynamic, targets: ["VoxOSNowPlaying"])
    ],
    targets: [
        .target(
            name: "VoxOSNowPlaying",
            dependencies: ["CVoxOSNowPlaying"],
            resources: [.copy("Resources/now-playing.pl")]
        ),
        .target(
            name: "CVoxOSNowPlaying",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .testTarget(name: "VoxOSNowPlayingTests", dependencies: ["VoxOSNowPlaying"]),
    ]
)
