import Foundation

struct OutputPathFormatter {
    private let options: RipgrepOptions
    private let currentDirectory: String

    init(
        options: RipgrepOptions,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.options = options
        self.currentDirectory = URL(fileURLWithPath: currentDirectory)
            .standardizedFileURL
            .path
    }

    func displayPath(for url: URL) -> String {
        if url.path == "-" || url.path == "<stdin>" {
            return "<stdin>"
        }

        let path = url.standardizedFileURL.path
        if let rootedPath = displayPathFromRootArgument(for: path) {
            return applyPathSeparator(rootedPath)
        }

        let prefix = currentDirectory.hasSuffix("/") ? currentDirectory : "\(currentDirectory)/"
        if path.hasPrefix(prefix) {
            var relativePath = String(path.dropFirst(prefix.count))
            if shouldPreserveCurrentDirectoryPrefix(for: url),
               !relativePath.hasPrefix("./") {
                relativePath = "./\(relativePath)"
            }
            return applyPathSeparator(relativePath)
        }

        return applyPathSeparator(path)
    }

    private func displayPathFromRootArgument(for path: String) -> String? {
        for (rootArgument, root) in zip(options.rootPathArguments, options.roots) {
            guard !rootArgument.isEmpty else {
                continue
            }
            let rootPath = root.standardizedFileURL.path
            guard let suffix = suffix(of: path, under: rootPath) else {
                continue
            }
            return append(suffix: suffix, toRootArgument: rootArgument)
        }
        return nil
    }

    private func suffix(of path: String, under rootPath: String) -> String? {
        if path == rootPath {
            return ""
        }
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard path.hasPrefix(rootPrefix) else {
            return nil
        }
        return String(path.dropFirst(rootPrefix.count))
    }

    private func append(suffix: String, toRootArgument rootArgument: String) -> String {
        guard !suffix.isEmpty else {
            return rootArgument
        }
        let root = rootArgument.trimmingTrailingSlashes()
        return "\(root)/\(suffix)"
    }

    private func shouldPreserveCurrentDirectoryPrefix(for url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        for (rootArgument, root) in zip(options.rootPathArguments, options.roots) {
            guard rootArgument == "." || rootArgument == "./" || rootArgument.hasPrefix("./") else {
                continue
            }
            let rootPath = root.standardizedFileURL.path
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
            if path == rootPath || path.hasPrefix(rootPrefix) {
                return true
            }
        }
        return false
    }

    private func applyPathSeparator(_ path: String) -> String {
        guard let pathSeparator = options.pathSeparator else {
            return path
        }
        return String(path.map { $0 == "/" ? pathSeparator : $0 })
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
