// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ripgrep",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ripgrep", targets: ["ripgrep"]),
    ],
    targets: [
        .target(
            name: "RipgrepCore",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "ripgrep",
            dependencies: ["RipgrepCore"]
        ),
        .testTarget(
            name: "RipgrepCoreTests",
            dependencies: ["RipgrepCore"]
        ),
    ]
)
