// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ChatGPTSwiftWeb",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "ChatGPTSwiftWeb", targets: ["ChatGPTSwiftWeb"]),
    ],
    targets: [
        .executableTarget(
            name: "ChatGPTSwiftWeb",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ]
)
