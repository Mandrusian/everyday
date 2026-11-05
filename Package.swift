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
        // The widget extension. Scripts/bundle.sh wraps it in an .appex inside the app.
        .executableTarget(
            name: "EverydayWidgets",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension"])]
        ),
        .executableTarget(
            name: "EverydayChecks",
            dependencies: ["EverydayCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
