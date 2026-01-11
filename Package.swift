// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DpiMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DpiMenuBar", targets: ["DpiMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "DpiMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
