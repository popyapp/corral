// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Corral",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Corral",
            path: "Sources/Corral"
        ),
        .testTarget(
            name: "CorralTests",
            dependencies: ["Corral"],
            path: "Tests/CorralTests"
        ),
    ]
)
