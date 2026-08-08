import Foundation

struct OutputPathFormatter {
    private struct RootMapping {
        let argument: String
        let path: String
        let prefix: String
    }

    private let options: RipgrepOptions
    private let currentDirectory: String
    private let currentDirectoryPrefix: String
    private let rootMappings: [RootMapping]
    private let currentDirectoryPreservingRoots: [RootMapping]

    init(
        options: RipgrepOptions,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.options = options
        let standardizedCurrentDirectory = URL(fileURLWithPath: currentDirectory)
            .standardizedFileURL
            .path
        self.currentDirectory = standardizedCurrentDirectory
        self.currentDirectoryPrefix = standardizedCurrentDirectory.hasSuffix("/")
            ? standardizedCurrentDirectory
            : "\(standardizedCurrentDirectory)/"
        self.rootMappings = zip(options.rootPathArguments, options.roots).compactMap { rootArgument, root in
            guard !rootArgument.isEmpty else {
                return nil
            }
            let rootPath = root.standardizedFileURL.path
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
            return RootMapping(argument: rootArgument, path: rootPath, prefix: rootPrefix)
        }
        self.currentDirectoryPreservingRoots = rootMappings.filter { mapping in
            mapping.argument == "." || mapping.argument == "./" || mapping.argument.hasPrefix("./")
        }
    }

    func displayPath(for url: URL, applyingPathSeparator: Bool = true) -> String {
        if isStdinSentinel(url) {
            return "<stdin>"
        }

        #if canImport(Darwin)
        let path = url.path
        #else
        let path = url.standardizedFileURL.path
        #endif
        if let rootedPath = displayPathFromRootArgument(for: path) {
            return normalizedPath(rootedPath, applyingPathSeparator: applyingPathSeparator)
        }

        if path.hasPrefix(currentDirectoryPrefix) {
            var relativePath = String(path.dropFirst(currentDirectoryPrefix.count))
            if shouldPreserveCurrentDirectoryPrefix(for: path),
               !relativePath.hasPrefix("./") {
                relativePath = "./\(relativePath)"
            }
            return normalizedPath(relativePath, applyingPathSeparator: applyingPathSeparator)
        }

        return normalizedPath(path, applyingPathSeparator: applyingPathSeparator)
    }

    private func isStdinSentinel(_ url: URL) -> Bool {
        #if canImport(Darwin)
        let path = url.path
        #else
        let path = url.standardizedFileURL.path
        #endif
        return path == "-"
            || path == "<stdin>"
            || (url.lastPathComponent == "<stdin>" && !FileManager.default.fileExists(atPath: path))
    }

    private func displayPathFromRootArgument(for path: String) -> String? {
        for mapping in rootMappings {
            guard let suffix = suffix(of: path, under: mapping) else {
                continue
            }
            return append(suffix: suffix, toRootArgument: mapping.argument)
        }
        return nil
    }

    private func suffix(of path: String, under mapping: RootMapping) -> String? {
        if path == mapping.path {
            return ""
        }
        guard path.hasPrefix(mapping.prefix) else {
            return nil
        }
        return String(path.dropFirst(mapping.prefix.count))
    }

    private func append(suffix: String, toRootArgument rootArgument: String) -> String {
        guard !suffix.isEmpty else {
            return rootArgument
        }
        let root = rootArgument.trimmingTrailingSlashes()
        return "\(root)/\(suffix)"
    }

    private func shouldPreserveCurrentDirectoryPrefix(for path: String) -> Bool {
        for root in currentDirectoryPreservingRoots {
            if path == root.path || path.hasPrefix(root.prefix) {
                return true
            }
        }
        return false
    }

    private func normalizedPath(_ path: String, applyingPathSeparator: Bool) -> String {
        let normalizedPath = path.utf8.allSatisfy(\.isASCII)
            ? path
            : path.precomposedStringWithCanonicalMapping
        #if os(Windows)
        let pathSeparator = applyingPathSeparator ? (options.pathSeparator ?? "\\") : "\\"
        return String(normalizedPath.map { $0 == "/" || $0 == "\\" ? pathSeparator : $0 })
        #else
        guard applyingPathSeparator else {
            return normalizedPath
        }
        guard let pathSeparator = options.pathSeparator else {
            return normalizedPath
        }
        return String(normalizedPath.map { $0 == "/" ? pathSeparator : $0 })
        #endif
    }
}

private extension UInt8 {
    var isASCII: Bool {
        self < 0x80
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var output = self
        while output.count > 1, output.last == "/" {
            output.removeLast()
        }
        return output
    }
}
