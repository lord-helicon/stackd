// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "stackd",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "stackd",
            path: "Sources/stackd"
        ),
        .testTarget(
            name: "stackdTests",
            dependencies: ["stackd"],
            path: "Tests/stackdTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
