// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacSweep",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "MacSweep",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MacSweep",
            // Sparkle.framework is copied into Contents/Frameworks by scripts/bundle.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "MacSweepTests", dependencies: ["MacSweep"], path: "Tests/MacSweepTests")
    ]
)
