// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DLNADrop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DLNADrop",
            path: "Sources/DLNADrop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
