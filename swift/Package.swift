// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ChatGPTSwiftWeb",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "ChatGPTSwiftWebCore", targets: ["ChatGPTSwiftWebCore"]),
        .executable(name: "ChatGPTSwiftWeb", targets: ["ChatGPTSwiftWeb"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        .target(
            name: "ChatGPTSwiftWebCore"
        ),
        .executableTarget(
            name: "ChatGPTSwiftWeb",
            dependencies: [
                "ChatGPTSwiftWebCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("WebKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "ChatGPTSwiftWebCoreTests",
            dependencies: ["ChatGPTSwiftWebCore"]
        ),
        .testTarget(
            name: "ChatGPTSwiftWebIntegrationTests",
            dependencies: ["ChatGPTSwiftWeb"]
        ),
    ]
)
