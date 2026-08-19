// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SunoFlow",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SunoFlow",
            path: "Sources/SunoFlow"
        )
    ]
)
