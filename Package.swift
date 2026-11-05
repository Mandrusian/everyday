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
            // Start Apple's extension runtime before it calls the Swift @main entry.
            // Entering WidgetBundle.main directly traps in ExtensionFoundation on macOS 27.
            // Keep _main even in release builds: NSExtensionMain discovers it via __swift5_entry.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-application_extension",
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                "-Xlinker", "-u", "-Xlinker", "_main",
            ])]
        ),
        .executableTarget(
            name: "EverydayChecks",
            dependencies: ["EverydayCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
