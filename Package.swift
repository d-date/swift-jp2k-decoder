// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "swift-jp2k-decoder",
    // Array.mutableSpan (Tier-1 hot loops) needs the OS 26 Apple runtimes;
    // Linux, Windows and Android have no such floor.
    platforms: [.macOS(.v26), .iOS(.v26), .tvOS(.v26), .watchOS(.v26), .visionOS(.v26)],
    products: [.library(name: "JP2K", targets: ["JP2K"])],
    targets: [
        .target(
            name: "JP2K",
            swiftSettings: [
                .strictMemorySafety(),
                .treatAllWarnings(as: .error),
            ]
        ),
        .executableTarget(name: "jp2k-bench", dependencies: ["JP2K"]),
        .testTarget(
            name: "JP2KTests",
            dependencies: ["JP2K"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "JP2KImageIOTests", dependencies: ["JP2K"]),
    ],
    swiftLanguageModes: [.v6]
)
