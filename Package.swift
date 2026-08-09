// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let environment = ProcessInfo.processInfo.environment
#if os(macOS) && arch(arm64)
let useCShim = environment["SWIFT_RIPGREP_USE_C_SHIM"] == "1"
    && environment["SWIFT_RIPGREP_NO_C_SHIM"] != "1"
#else
let useCShim = false
#endif

#if os(Linux) && arch(x86_64)
let useLinuxPreflightShim = true
#else
let useLinuxPreflightShim = false
#endif

#if os(macOS)
let coreExcludes: [String] = []
let executableExcludes = ["PortableMain.swift"]
#else
let coreExcludes = ["SwiftDarwinLiteralPreflight.swift"]
let executableExcludes = ["ripgrep.swift"]
#endif

var targets: [Target] = []
if useCShim {
    targets.append(.target(name: "CRipgrepPlatform"))
}
if useLinuxPreflightShim {
    targets.append(.target(name: "CLinuxPreflight"))
}
var coreDependencies: [Target.Dependency] = []
if useCShim {
    coreDependencies.append("CRipgrepPlatform")
}
if useLinuxPreflightShim {
    coreDependencies.append("CLinuxPreflight")
}
targets.append(
    .target(
        name: "RipgrepCore",
        dependencies: coreDependencies,
        exclude: coreExcludes,
        resources: [
            .process("Resources"),
        ]
    )
)
targets.append(
    .executableTarget(
        name: "ripgrep",
        dependencies: useCShim ? ["RipgrepCore", "CRipgrepPlatform"] : ["RipgrepCore"],
        exclude: executableExcludes
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
