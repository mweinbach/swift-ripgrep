// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let useCShim = ProcessInfo.processInfo.environment["SWIFT_RIPGREP_NO_C_SHIM"] != "1"

var targets: [Target] = []
if useCShim {
    targets.append(.target(name: "CRipgrepPlatform"))
}
targets.append(
    .target(
        name: "RipgrepCore",
        dependencies: useCShim ? ["CRipgrepPlatform"] : [],
        resources: [
            .process("Resources"),
        ]
    )
)
targets.append(
    .executableTarget(
        name: "ripgrep",
        dependencies: useCShim ? ["RipgrepCore", "CRipgrepPlatform"] : ["RipgrepCore"]
    )
)
targets.append(
    .testTarget(
        name: "RipgrepCoreTests",
        dependencies: ["RipgrepCore"]
    )
)

let package = Package(
    name: "ripgrep",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ripgrep", targets: ["ripgrep"]),
    ],
    targets: targets
)
