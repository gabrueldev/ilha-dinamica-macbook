// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ilha",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Ilha",
            path: "Sources/Ilha"
        )
    ]
)
