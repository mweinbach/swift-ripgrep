// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

struct PCRE2BuildSettings {
    var swiftFlags: [String]
    var linkerFlags: [String]

    static func detect() -> PCRE2BuildSettings {
        if let pkgConfig = run("pkg-config", arguments: ["--cflags", "--libs", "libpcre2-8"]),
           !pkgConfig.contains("@@") {
            return parse(flags: pkgConfig)
        }
        if let pcre2Config = run("pcre2-config", arguments: ["--cflags", "--libs8"]),
           !pcre2Config.contains("@@") {
            return parse(flags: pcre2Config)
        }
        for prefix in ["/opt/homebrew/opt/pcre2", "/usr/local/opt/pcre2"] {
            if FileManager.default.fileExists(atPath: "\(prefix)/include/pcre2.h") {
                return PCRE2BuildSettings(
                    swiftFlags: ["-Xcc", "-I\(prefix)/include"],
                    linkerFlags: ["-L\(prefix)/lib", "-lpcre2-8"]
                )
            }
        }
        return PCRE2BuildSettings(swiftFlags: [], linkerFlags: ["-lpcre2-8"])
    }

    private static func parse(flags: String) -> PCRE2BuildSettings {
        var swiftFlags: [String] = []
        var linkerFlags: [String] = []
        for flag in flags.split(whereSeparator: \.isWhitespace).map(String.init) {
            if flag.hasPrefix("-I") {
                swiftFlags.append(contentsOf: ["-Xcc", flag])
            } else if flag.hasPrefix("-L") || flag.hasPrefix("-l") {
                linkerFlags.append(flag)
            }
        }
        if !linkerFlags.contains("-lpcre2-8") {
            linkerFlags.append("-lpcre2-8")
        }
        return PCRE2BuildSettings(swiftFlags: swiftFlags, linkerFlags: linkerFlags)
    }

    private static func run(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]) { current, _ in current }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

let pcre2BuildSettings = PCRE2BuildSettings.detect()

let package = Package(
    name: "ripgrep",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ripgrep", targets: ["ripgrep"]),
    ],
    targets: [
        .systemLibrary(
            name: "CPCRE2",
            pkgConfig: "libpcre2-8",
            providers: [.brew(["pcre2"])]
        ),
        .target(
            name: "RipgrepCore",
            dependencies: ["CPCRE2"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .unsafeFlags(pcre2BuildSettings.swiftFlags),
            ],
            linkerSettings: [
                .unsafeFlags(pcre2BuildSettings.linkerFlags),
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
