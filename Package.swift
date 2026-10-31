// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hortai",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Hortai",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
