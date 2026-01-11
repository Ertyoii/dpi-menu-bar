// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DpiMenuBar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "DpiMenuBar", targets: ["DpiMenuBar"]),
    ],
    targets: [
        .executableTarget(
            name: "DpiMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "DpiMenuBarTests",
            dependencies: ["DpiMenuBar"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
