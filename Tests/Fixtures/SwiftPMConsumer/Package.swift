// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RipgrepCoreConsumer",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "RipgrepCoreConsumer", targets: ["RipgrepCoreConsumer"]),
    ],
    dependencies: [
        .package(path: "../../.."),
    ],
    targets: [
        .executableTarget(
            name: "RipgrepCoreConsumer",
            dependencies: [
                .product(name: "RipgrepCore", package: "swift-ripgrep"),
            ]
        ),
    ]
)
