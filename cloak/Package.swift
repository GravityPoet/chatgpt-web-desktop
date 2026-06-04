// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ChatGPTCloakLauncher",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "ChatGPTCloakLauncher", targets: ["ChatGPTCloakLauncher"]),
    ],
    targets: [
        .executableTarget(
            name: "ChatGPTCloakLauncher",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
