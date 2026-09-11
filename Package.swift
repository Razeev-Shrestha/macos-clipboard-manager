// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "ClipboardManager",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "ClipboardCore",
            targets: ["ClipboardCore"]
        )
    ],
    targets: [
        .target(
            name: "ClipboardCore",
            path: "Sources/ClipboardCore"
        ),
        .testTarget(
            name: "ClipboardCoreTests",
            dependencies: ["ClipboardCore"],
            path: "Tests/ClipboardCoreTests"
        )
    ]
)
