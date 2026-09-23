// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BeatSnap",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BeatSnapAnalysis", targets: ["BeatSnapAnalysis"]),
        .executable(name: "beatsnap-analyze", targets: ["beatsnap-analyze"]),
        .executable(name: "BeatSnapApp", targets: ["BeatSnapApp"]),
    ],
    targets: [
        .target(name: "BeatSnapAnalysis"),
        .executableTarget(name: "beatsnap-analyze", dependencies: ["BeatSnapAnalysis"]),
        .executableTarget(
            name: "BeatSnapApp",
            dependencies: ["BeatSnapAnalysis"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "BeatSnapAppTests", dependencies: ["BeatSnapApp"]),
    ]
)
