// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "everyday",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Everyday", targets: ["Everyday"]),
        .library(name: "EverydayCore", targets: ["EverydayCore"]),
    ],
    targets: [
        .target(
            name: "EverydayCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Everyday",
            dependencies: ["EverydayCore"]
        ),
        .executableTarget(
            name: "EverydayChecks",
            dependencies: ["EverydayCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
