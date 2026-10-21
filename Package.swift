// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DBGram",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DBGram", targets: ["DBGram"]),
        .library(name: "DBMLKit", targets: ["DBMLKit"]),
    ],
    targets: [
        .target(name: "DBMLKit"),
        .executableTarget(
            name: "DBGram",
            dependencies: ["DBMLKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "DBMLKitTests", dependencies: ["DBMLKit"]),
    ]
)
