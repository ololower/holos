// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Holos",
    platforms: [.macOS(.v14)],
    targets: [
        // whisper.cpp b5130 (v1.9.4), офіційний xcframework з GitHub releases
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .executableTarget(
            name: "Holos",
            dependencies: ["whisper"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
