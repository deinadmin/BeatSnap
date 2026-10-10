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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "BeatSnapAnalysis"),
        .executableTarget(name: "beatsnap-analyze", dependencies: ["BeatSnapAnalysis"]),
        .executableTarget(
            name: "BeatSnapApp",
            dependencies: [
                "BeatSnapAnalysis",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // build-app.sh embeds Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "BeatSnapAppTests", dependencies: ["BeatSnapApp"]),
    ]
)
