#if os(Linux) && arch(x86_64)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import CLinuxPreflight

/// Conservative executable-level fast paths for explicit regular files and
/// sorted directory trees. Unsupported shapes fall back to the full engine.
public enum LinuxX86LiteralPreflight {
    private static let maximumBufferedBytes = 512 * 1024 * 1024
    private static let maximumBufferedLineSpans = 256 * 1024

    private enum Mode {
        case matchingLines
        case countLines
    }

    private enum PreflightPattern {
        case literal([UInt8])
        case asciiCaseInsensitiveLiteral([UInt8])
        case literalAlternation([[UInt8]])
        case capitalizedWordWhitespaceSuffix([UInt8])
    }

    private enum LiteralSearchEvent {
        case literal(Int)
        case binary
    }

    private enum SortedDirectoryMode {
        case files
        case matchingLines
        case countLines
        case filesWithMatches
    }

    private struct SortedDirectoryInvocation {
        let mode: SortedDirectoryMode
        let literal: [UInt8]?
        let rootPath: String
    }

    private struct SortedDirectoryFile {
        let path: String
        let pathBytes: [UInt8]
        let components: [String]
    }

    private struct ReusableFileBuffer {
        private(set) var storage: UnsafeMutablePointer<UInt8>?
        private(set) var capacity = 0

        mutating func reserveCapacity(_ requestedCapacity: Int) -> Bool {
            guard requestedCapacity > capacity else { return true }
            let newCapacity = max(requestedCapacity, max(256 * 1024, capacity * 2))
            let replacement = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
            storage?.deallocate()
            storage = replacement
            capacity = newCapacity
            return true
        }

        mutating func deallocate() {
            storage?.deallocate()
            storage = nil
            capacity = 0
        }
    }

    public static func run(arguments: [String]) -> Int32? {
        guard !environmentVariableExists("SWIFT_RIPGREP_NO_LINUX_X86_PREFLIGHT"),
              !environmentVariableExists("RIPGREP_CONFIG_PATH"),
              isatty(STDOUT_FILENO) == 0 else {
            return nil
        }

        if let invocation = parseSortedDirectory(arguments),
           let result = runSortedDirectory(invocation) {
            return result
        }

        guard let parsed = parse(arguments),
              let pattern = preflightPattern(
                parsed.pattern,
                mode: parsed.mode,
                asciiCaseInsensitive: parsed.asciiCaseInsensitive
              ) else {
            return nil
        }

        let descriptor = parsed.path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(Int.max) else {
            return nil
        }
        let size = Int(metadata.st_size)
        guard size > 0 else { return 1 }

        if parsed.buffered {
            guard size <= maximumBufferedBytes else { return nil }
            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: size,
                alignment: MemoryLayout<UInt8>.alignment
            )
            defer { storage.deallocate() }
            var bytesRead = 0
            while bytesRead < size {
                let result = read(
                    descriptor,
                    storage.advanced(by: bytesRead),
                    size - bytesRead
                )
                guard result >= 0 else { return nil }
                guard result > 0 else { break }
                bytesRead += result
            }
            guard bytesRead > 0 else { return 1 }
            let bytes = UnsafePointer(storage.assumingMemoryBound(to: UInt8.self))
            return runScan(
                bytes: bytes,
                count: bytesRead,
                mode: parsed.mode,
                pattern: pattern
            )
        }

        guard let mapping = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0),
              mapping != MAP_FAILED else {
            return nil
        }
        defer { _ = munmap(mapping, size) }

        let bytes = UnsafeRawPointer(mapping).assumingMemoryBound(to: UInt8.self)
        return runScan(bytes: bytes, count: size, mode: parsed.mode, pattern: pattern)
    }

    private static func parseSortedDirectory(_ arguments: [String]) -> SortedDirectoryInvocation? {
        var argumentIndex = 0
        var sawPathSort = false
        leadingFlags: while argumentIndex < arguments.count {
            switch arguments[argumentIndex] {
            case "--no-config", "--color=never":
                argumentIndex += 1
            case "--color":
                guard argumentIndex + 1 < arguments.count,
                      arguments[argumentIndex + 1] == "never" else {
                    return nil
                }
                argumentIndex += 2
            case "--sort":
                guard !sawPathSort,
                      argumentIndex + 1 < arguments.count,
                      arguments[argumentIndex + 1] == "path" else {
                    return nil
                }
                sawPathSort = true
                argumentIndex += 2
            case "--sort=path":
                guard !sawPathSort else { return nil }
                sawPathSort = true
                argumentIndex += 1
            default:
                break leadingFlags
            }
        }
        guard sawPathSort else { return nil }

        let remaining = Array(arguments.dropFirst(argumentIndex))
        let mode: SortedDirectoryMode
        let literal: [UInt8]?
        let rootPath: String
        if remaining.count == 2, remaining[0] == "--files" {
            mode = .files
            literal = nil
            rootPath = remaining[1]
        } else if remaining.count == 2 {
            mode = .matchingLines
            guard let parsedLiteral = plainLiteralBytes(remaining[0]) else { return nil }
            literal = parsedLiteral
            rootPath = remaining[1]
        } else if remaining.count == 3,
                  remaining[0] == "-c" || remaining[0] == "--count" {
            mode = .countLines
            guard let parsedLiteral = plainLiteralBytes(remaining[1]) else { return nil }
            literal = parsedLiteral
            rootPath = remaining[2]
        } else if remaining.count == 3,
                  remaining[0] == "-l" || remaining[0] == "--files-with-matches" {
            mode = .filesWithMatches
            guard let parsedLiteral = plainLiteralBytes(remaining[1]) else { return nil }
            literal = parsedLiteral
            rootPath = remaining[2]
        } else {
            return nil
        }

        guard rootPath.hasPrefix("/"),
              rootPath != "/",
              rootPath.utf8.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        return SortedDirectoryInvocation(mode: mode, literal: literal, rootPath: rootPath)
    }

    private static func runSortedDirectory(_ invocation: SortedDirectoryInvocation) -> Int32? {
        let rootPath = trimTrailingSeparators(invocation.rootPath)
        var rootMetadata = stat()
        let rootStatus = rootPath.withCString { lstat($0, &rootMetadata) }
        guard rootStatus == 0,
              (rootMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              !ancestorContainsIgnoreMetadata(rootPath) else {
            return nil
        }

        var files: [SortedDirectoryFile] = []
        files.reserveCapacity(256)
        guard collectSortedDirectoryFiles(
            physicalDirectory: rootPath,
            outputDirectory: rootPath,
            components: [],
            requiresFileMetadata: invocation.mode != .files,
            files: &files
        ) else {
            return nil
        }
        files.sort { pathComponentsPrecede($0.components, $1.components) }

        var output = POSIXOutputBuffer(capacity: 64 * 1024)
        defer { output.deallocate() }
        if invocation.mode == .files {
            for file in files {
                guard output.writeBytes(file.pathBytes),
                      output.writeByte(UInt8(ascii: "\n")) else {
                    return 2
                }
            }
            guard output.flush() else { return 2 }
            return files.isEmpty ? 1 : 0
        }

        guard let literal = invocation.literal else { return nil }
        var buffer = ReusableFileBuffer()
        defer { buffer.deallocate() }
        var matches: [(file: SortedDirectoryFile, count: Int)] = []
        matches.reserveCapacity(files.count)
        for file in files {
            guard let count = readLiteralMatchedLineCount(
                path: file.path,
                literal: literal,
                stopAfterFirst: invocation.mode == .filesWithMatches,
                buffer: &buffer
            ) else {
                return nil
            }
            if count > 0 {
                matches.append((file, count))
            }
        }

        for match in matches {
            if invocation.mode == .matchingLines {
                guard let wroteLines = withFileBytes(path: match.file.path, buffer: &buffer, { bytes, count in
                    writeRecursiveLiteralMatchingLines(
                        pathBytes: match.file.pathBytes,
                        bytes: bytes,
                        count: count,
                        literal: literal,
                        output: &output
                    )
                }), wroteLines else {
                    return 2
                }
            } else if invocation.mode == .countLines {
                guard output.writeBytes(match.file.pathBytes),
                      output.writeByte(UInt8(ascii: ":")),
                      output.writeDecimal(match.count, terminator: UInt8(ascii: "\n")) else {
                    return 2
                }
            } else {
                guard output.writeBytes(match.file.pathBytes),
                      output.writeByte(UInt8(ascii: "\n")) else {
                    return 2
                }
            }
        }
        guard output.flush() else { return 2 }
        return matches.isEmpty ? 1 : 0
    }

    private static func trimTrailingSeparators(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func parentDirectory(_ path: String) -> String {
        guard path != "/", let separator = path.lastIndex(of: "/") else { return "/" }
        return separator == path.startIndex ? "/" : String(path[..<separator])
    }

    private static func ancestorContainsIgnoreMetadata(_ rootPath: String) -> Bool {
        let markerNames = [".git", ".gitignore", ".ignore", ".rgignore"]
        var directory = parentDirectory(rootPath)
        while true {
            for marker in markerNames {
                let markerPath = directory == "/" ? "/\(marker)" : "\(directory)/\(marker)"
                var metadata = stat()
                errno = 0
                if markerPath.withCString({ lstat($0, &metadata) }) == 0 {
                    return true
                }
                if errno != ENOENT && errno != ENOTDIR {
                    return true
                }
            }
            if directory == "/" { break }
            directory = parentDirectory(directory)
        }
        return false
    }

    private static func collectSortedDirectoryFiles(
        physicalDirectory: String,
        outputDirectory: String,
        components: [String],
        requiresFileMetadata: Bool,
        files: inout [SortedDirectoryFile]
    ) -> Bool {
        guard let directory = physicalDirectory.withCString({ opendir($0) }) else {
            return false
        }
        defer { _ = closedir(directory) }

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                return errno == 0
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard name.utf8.allSatisfy({ $0 < 0x80 }) else { return false }
            if name == ".git" || name == ".gitignore" || name == ".ignore" || name == ".rgignore" {
                return false
            }
            if name.hasPrefix(".") { continue }

            let physicalPath = physicalDirectory + "/" + name
            let outputPath = outputDirectory + "/" + name
            let directoryEntryType = entry.pointee.d_type
            if directoryEntryType == UInt8(DT_LNK) {
                continue
            }
            let childComponents = components + [name]
            if directoryEntryType == UInt8(DT_DIR) {
                guard collectSortedDirectoryFiles(
                    physicalDirectory: physicalPath,
                    outputDirectory: outputPath,
                    components: childComponents,
                    requiresFileMetadata: requiresFileMetadata,
                    files: &files
                ) else {
                    return false
                }
            } else if directoryEntryType == UInt8(DT_REG) {
                if requiresFileMetadata {
                    var metadata = stat()
                    guard physicalPath.withCString({ lstat($0, &metadata) }) == 0,
                          (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                          metadata.st_size >= 0,
                          UInt64(metadata.st_size) <= UInt64(maximumBufferedBytes) else {
                        return false
                    }
                }
                files.append(SortedDirectoryFile(
                    path: outputPath,
                    pathBytes: Array(outputPath.utf8),
                    components: childComponents
                ))
            } else if directoryEntryType == UInt8(DT_UNKNOWN) {
                var metadata = stat()
                guard physicalPath.withCString({ lstat($0, &metadata) }) == 0 else {
                    return false
                }
                let fileType = metadata.st_mode & mode_t(S_IFMT)
                if fileType == mode_t(S_IFLNK) {
                    continue
                }
                if fileType == mode_t(S_IFDIR) {
                    guard collectSortedDirectoryFiles(
                        physicalDirectory: physicalPath,
                        outputDirectory: outputPath,
                        components: childComponents,
                        requiresFileMetadata: requiresFileMetadata,
                        files: &files
                    ) else {
                        return false
                    }
                } else if fileType == mode_t(S_IFREG),
                          (!requiresFileMetadata
                           || (metadata.st_size >= 0
                               && UInt64(metadata.st_size) <= UInt64(maximumBufferedBytes))) {
                    files.append(SortedDirectoryFile(
                        path: outputPath,
                        pathBytes: Array(outputPath.utf8),
                        components: childComponents
                    ))
                } else {
                    return false
                }
            } else {
                return false
            }
        }
    }

    private static func pathComponentsPrecede(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) {
            if left != right { return left < right }
        }
        return lhs.count < rhs.count
    }

    private static func readLiteralMatchedLineCount(
        path: String,
        literal: [UInt8],
        stopAfterFirst: Bool,
        buffer: inout ReusableFileBuffer
    ) -> Int? {
        guard let result = withFileBytes(path: path, buffer: &buffer, { bytes, count in
            if let count = scanLiteral(
                bytes: bytes,
                count: count,
                literal: literal,
                stopAfterFirst: stopAfterFirst
            ) {
                return (valid: true, count: count)
            }
            return (valid: false, count: 0)
        }), result.valid else {
            return nil
        }
        return result.count
    }

    private static func withFileBytes<Result>(
        path: String,
        buffer: inout ReusableFileBuffer,
        _ body: (UnsafePointer<UInt8>, Int) -> Result
    ) -> Result? {
        let descriptor = path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(maximumBufferedBytes) else {
            return nil
        }
        let size = Int(metadata.st_size)
        guard size > 0 else {
            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1) {
                body(UnsafePointer($0.baseAddress!), 0)
            }
        }
        guard buffer.reserveCapacity(size), let bytes = buffer.storage else { return nil }

        var bytesRead = 0
        while bytesRead < size {
            let result = read(descriptor, bytes.advanced(by: bytesRead), size - bytesRead)
            guard result > 0 else { return nil }
            bytesRead += result
        }
        guard hasSupportedByteOrderMark(UnsafePointer(bytes), count: bytesRead) else { return nil }
        return body(UnsafePointer(bytes), bytesRead)
    }

    private static func writeRecursiveLiteralMatchingLines(
        pathBytes: [UInt8],
        bytes: UnsafePointer<UInt8>,
        count: Int,
        literal: [UInt8],
        output: inout POSIXOutputBuffer
    ) -> Bool {
        var searchOffset = 0
        while searchOffset <= count - literal.count,
              let matchStart = findLiteral(bytes: bytes, range: searchOffset..<count, literal: literal) {
            var lineStart = matchStart
            while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") {
                lineStart -= 1
            }
            let newline = findByte(
                bytes.advanced(by: matchStart + literal.count),
                count: count - matchStart - literal.count,
                byte: UInt8(ascii: "\n")
            ).map { matchStart + literal.count + $0 }
            let outputEnd = newline.map { $0 + 1 } ?? count
            guard output.writeBytes(pathBytes),
                  output.writeByte(UInt8(ascii: ":")),
                  output.write(bytes.advanced(by: lineStart), count: outputEnd - lineStart) else {
                return false
            }
            if newline == nil, !output.writeByte(UInt8(ascii: "\n")) { return false }
            searchOffset = outputEnd
        }
        return true
    }

    private static func runScan(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        mode: Mode,
        pattern: PreflightPattern
    ) -> Int32? {
        guard hasSupportedByteOrderMark(bytes, count: count) else { return nil }
        switch mode {
        case .matchingLines:
            guard case .literal(let literal) = pattern else { return nil }
            return scanLiteralLines(bytes: bytes, count: count, literal: literal)
        case .countLines:
            let matchedLines: Int?
            if case .literal(let literal) = pattern {
                matchedLines = scanLiteral(bytes: bytes, count: count, literal: literal)
            } else if case .asciiCaseInsensitiveLiteral(let literal) = pattern {
                guard rg_linux_bytes_are_ascii_text(bytes, count) != 0 else { return nil }
                matchedLines = scanASCIICaseInsensitiveLiteral(
                    bytes: bytes,
                    count: count,
                    foldedLiteral: literal
                )
            } else if case .capitalizedWordWhitespaceSuffix(let suffix) = pattern {
                matchedLines = scanCapitalizedWordWhitespaceSuffix(
                    bytes: bytes,
                    count: count,
                    suffix: suffix
                )
            } else {
                guard canUseBytes(bytes, count: count) else { return nil }
                matchedLines = scanCount(bytes: bytes, count: count, pattern: pattern)
            }
            guard let matchedLines else { return nil }
            guard matchedLines > 0 else { return 1 }
            return writeDecimalLine(matchedLines) ? 0 : nil
        }
    }

    private static func environmentVariableExists(_ name: String) -> Bool {
        name.withCString { getenv($0) != nil }
    }

    private static func parse(
        _ arguments: [String]
    ) -> (
        mode: Mode,
        pattern: String,
        path: String,
        buffered: Bool,
        asciiCaseInsensitive: Bool
    )? {
        var argumentIndex = 0
        var buffered = false
        var asciiCaseInsensitive = false
        leadingFlags: while argumentIndex < arguments.count {
            switch arguments[argumentIndex] {
            case "--no-config", "--color=never":
                argumentIndex += 1
            case "--no-mmap":
                buffered = true
                argumentIndex += 1
            case "-i", "--ignore-case":
                guard !asciiCaseInsensitive else { return nil }
                asciiCaseInsensitive = true
                argumentIndex += 1
            case "--color":
                guard argumentIndex + 1 < arguments.count,
                      arguments[argumentIndex + 1] == "never" else {
                    return nil
                }
                argumentIndex += 2
            default:
                break leadingFlags
            }
        }
        let remaining = arguments.dropFirst(argumentIndex)
        let mode: Mode
        let pattern: String
        let path: String
        if remaining.count == 2 {
            mode = .matchingLines
            pattern = remaining[remaining.startIndex]
            path = remaining[remaining.index(after: remaining.startIndex)]
        } else if remaining.count == 3,
                  remaining[remaining.startIndex] == "-c"
                    || remaining[remaining.startIndex] == "--count" {
            mode = .countLines
            let patternIndex = remaining.index(after: remaining.startIndex)
            let pathIndex = remaining.index(after: patternIndex)
            pattern = remaining[patternIndex]
            path = remaining[pathIndex]
        } else {
            return nil
        }
        guard !pattern.hasPrefix("-"), path != "-", !path.isEmpty else {
            return nil
        }
        guard !asciiCaseInsensitive || mode == .countLines else { return nil }
        return (mode, pattern, path, buffered, asciiCaseInsensitive)
    }

    private static func plainLiteralBytes(_ pattern: String) -> [UInt8]? {
        guard !pattern.isEmpty,
              !pattern.utf8.contains(0),
              !pattern.contains("\n"),
              !pattern.contains("\r") else {
            return nil
        }
        let regexMetacharacters = "\\.^$*+?()[]{}|"
        guard !pattern.contains(where: { regexMetacharacters.contains($0) }) else {
            return nil
        }
        let bytes = Array(pattern.utf8)
        return bytes.isEmpty ? nil : bytes
    }

    private static func preflightPattern(
        _ pattern: String,
        mode: Mode,
        asciiCaseInsensitive: Bool
    ) -> PreflightPattern? {
        if let literal = plainLiteralBytes(pattern) {
            if asciiCaseInsensitive {
                guard mode == .countLines,
                      literal.allSatisfy({ $0 < 0x80 }) else {
                    return nil
                }
                return .asciiCaseInsensitiveLiteral(literal.map { asciiLowercased($0) })
            }
            return .literal(literal)
        }
        guard !asciiCaseInsensitive else { return nil }
        guard mode == .countLines else { return nil }
        let branches = pattern.split(separator: "|", omittingEmptySubsequences: false)
        if branches.count >= 2, branches.count <= 8 {
            let literals = branches.compactMap { plainLiteralBytes(String($0)) }
            if literals.count == branches.count {
                return .literalAlternation(literals)
            }
        }

        let prefix = #"[A-Z][a-z]+\s+"#
        guard pattern.hasPrefix(prefix) else { return nil }
        let suffix = String(pattern.dropFirst(prefix.count))
        guard let literal = plainLiteralBytes(suffix),
              literal.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        return .capitalizedWordWhitespaceSuffix(literal)
    }

    private static func hasSupportedByteOrderMark(
        _ bytes: UnsafePointer<UInt8>,
        count: Int
    ) -> Bool {
        if count >= 3,
           bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return false
        }
        if count >= 2,
           ((bytes[0] == 0xFF && bytes[1] == 0xFE)
            || (bytes[0] == 0xFE && bytes[1] == 0xFF)) {
            return false
        }
        return true
    }

    private static func canUseBytes(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        hasSupportedByteOrderMark(bytes, count: count) && memchr(bytes, 0, count) == nil
    }

    private static func scanCount(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        pattern: PreflightPattern
    ) -> Int? {
        switch pattern {
        case .literal(let literal):
            return scanLiteral(bytes: bytes, count: count, literal: literal)
        case .asciiCaseInsensitiveLiteral:
            return nil
        case .literalAlternation(let literals):
            return scanLiteralAlternation(bytes: bytes, count: count, literals: literals)
        case .capitalizedWordWhitespaceSuffix(let suffix):
            return scanCapitalizedWordWhitespaceSuffix(
                bytes: bytes,
                count: count,
                suffix: suffix
            )
        }
    }

    private static func scanLiteralLines(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        literal: [UInt8]
    ) -> Int32? {
        var lines: [(start: Int, end: Int, needsNewline: Bool)] = []
        var searchOffset = 0
        while searchOffset < count {
            guard let event = findLiteralOrBinary(
                bytes: bytes,
                range: searchOffset..<count,
                literal: literal
            ) else {
                break
            }
            guard case .literal(let matchStart) = event else { return nil }
            var lineStart = matchStart
            while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") {
                lineStart -= 1
            }
            let newline = findByte(
                bytes.advanced(by: matchStart),
                count: count - matchStart,
                byte: UInt8(ascii: "\n")
            ).map { matchStart + $0 }
            let lineEnd = newline ?? count
            let outputEnd = newline.map { $0 + 1 } ?? count
            guard matchStart + literal.count <= lineEnd else {
                searchOffset = matchStart + 1
                continue
            }
            if outputEnd > matchStart + 1,
               memchr(bytes.advanced(by: matchStart + 1), 0, outputEnd - matchStart - 1) != nil {
                return nil
            }
            guard lines.count < maximumBufferedLineSpans else { return nil }
            lines.append((lineStart, outputEnd, newline == nil))
            searchOffset = outputEnd
        }
        guard !lines.isEmpty else { return 1 }
        for line in lines {
            guard writeAll(bytes.advanced(by: line.start), count: line.end - line.start) else {
                return nil
            }
            if line.needsNewline {
                var newlineByte = UInt8(ascii: "\n")
                guard withUnsafePointer(to: &newlineByte, { writeAll($0, count: 1) }) else {
                    return nil
                }
            }
        }
        return 0
    }

    private static func scanLiteral(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        literal: [UInt8],
        stopAfterFirst: Bool = false
    ) -> Int? {
        var matchedLines = 0
        var searchOffset = 0
        while searchOffset < count {
            guard let event = findLiteralOrBinary(
                bytes: bytes,
                range: searchOffset..<count,
                literal: literal
            ) else {
                break
            }
            guard case .literal(let matchStart) = event else { return nil }
            let newline = findByte(
                bytes.advanced(by: matchStart),
                count: count - matchStart,
                byte: UInt8(ascii: "\n")
            ).map { matchStart + $0 }
            let lineEnd = newline ?? count
            guard matchStart + literal.count <= lineEnd else {
                searchOffset = matchStart + 1
                continue
            }
            let outputEnd = newline.map { $0 + 1 } ?? count
            if outputEnd > matchStart + 1,
               memchr(bytes.advanced(by: matchStart + 1), 0, outputEnd - matchStart - 1) != nil {
                return nil
            }
            matchedLines += 1
            if stopAfterFirst {
                if outputEnd < count,
                   memchr(bytes.advanced(by: outputEnd), 0, count - outputEnd) != nil {
                    return nil
                }
                return 1
            }
            searchOffset = outputEnd
        }
        return matchedLines
    }

    private static func scanASCIICaseInsensitiveLiteral(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        foldedLiteral: [UInt8]
    ) -> Int {
        var matchedLines = 0
        var searchOffset = 0
        while searchOffset <= count - foldedLiteral.count {
            let found = foldedLiteral.withUnsafeBufferPointer { literalBuffer in
                rg_linux_memcasemem_ascii(
                    bytes.advanced(by: searchOffset),
                    count - searchOffset,
                    literalBuffer.baseAddress,
                    literalBuffer.count
                )
            }
            guard let found else { break }
            let matchStart = bytes.distance(to: found)
            let newline = findByte(
                bytes.advanced(by: matchStart),
                count: count - matchStart,
                byte: UInt8(ascii: "\n")
            ).map { matchStart + $0 }
            let lineEnd = newline ?? count
            guard matchStart + foldedLiteral.count <= lineEnd else {
                searchOffset = matchStart + 1
                continue
            }
            matchedLines += 1
            searchOffset = newline.map { $0 + 1 } ?? count
        }
        return matchedLines
    }

    @inline(__always)
    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
            ? byte + (UInt8(ascii: "a") - UInt8(ascii: "A"))
            : byte
    }

    @inline(__always)
    private static func findLiteralOrBinary(
        bytes: UnsafePointer<UInt8>,
        range: Range<Int>,
        literal: [UInt8]
    ) -> LiteralSearchEvent? {
        guard let first = literal.first else { return nil }
        var searchOffset = range.lowerBound
        while searchOffset < range.upperBound {
            var matchedBinary: Int32 = 0
            guard let found = rg_linux_find_either_byte(
                bytes.advanced(by: searchOffset),
                range.upperBound - searchOffset,
                first,
                0,
                &matchedBinary
            ) else {
                return nil
            }
            let candidate = bytes.distance(to: found)
            if matchedBinary != 0 { return .binary }
            if candidate <= range.upperBound - literal.count,
               literalMatches(bytes: bytes, at: candidate, literal: literal) {
                return .literal(candidate)
            }
            searchOffset = candidate + 1
        }
        return nil
    }

    private static func scanLiteralAlternation(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        literals: [[UInt8]]
    ) -> Int {
        var matchedLines = 0
        var searchOffset = 0
        while searchOffset < count,
              let match = earliestLiteralMatch(
                bytes: bytes,
                range: searchOffset..<count,
                literals: literals
              ) {
            let newline = findByte(
                bytes.advanced(by: match.start),
                count: count - match.start,
                byte: UInt8(ascii: "\n")
            ).map { match.start + $0 }
            let lineEnd = newline ?? count
            guard match.start + match.length <= lineEnd else {
                searchOffset = match.start + 1
                continue
            }
            matchedLines += 1
            searchOffset = newline.map { $0 + 1 } ?? count
        }
        return matchedLines
    }

    private static func earliestLiteralMatch(
        bytes: UnsafePointer<UInt8>,
        range: Range<Int>,
        literals: [[UInt8]]
    ) -> (start: Int, length: Int)? {
        var earliest: (start: Int, length: Int)?
        for literal in literals {
            guard let start = findLiteral(bytes: bytes, range: range, literal: literal) else {
                continue
            }
            if earliest == nil || start < earliest!.start {
                earliest = (start, literal.count)
            }
        }
        return earliest
    }

    private static func scanCapitalizedWordWhitespaceSuffix(
        bytes: UnsafePointer<UInt8>,
        count: Int,
        suffix: [UInt8]
    ) -> Int? {
        var matchedLines = 0
        var searchOffset = 0
        while searchOffset < count {
            guard let event = findLiteralOrBinary(
                bytes: bytes,
                range: searchOffset..<count,
                literal: suffix
            ) else {
                break
            }
            guard case .literal(let suffixStart) = event else { return nil }
            var lineStart = suffixStart
            while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") {
                lineStart -= 1
            }
            let newline = findByte(
                bytes.advanced(by: suffixStart),
                count: count - suffixStart,
                byte: UInt8(ascii: "\n")
            ).map { suffixStart + $0 }
            let lineEnd = newline ?? count
            let outputEnd = newline.map { $0 + 1 } ?? count
            guard suffixStart + suffix.count <= lineEnd else {
                searchOffset = suffixStart + 1
                continue
            }
            if outputEnd > suffixStart + 1,
               memchr(bytes.advanced(by: suffixStart + 1), 0, outputEnd - suffixStart - 1) != nil {
                return nil
            }
            guard let matches = matchesCapitalizedWordWhitespacePrefix(
                bytes: bytes,
                lineStart: lineStart,
                suffixStart: suffixStart
            ) else {
                return nil
            }
            if matches {
                matchedLines += 1
                searchOffset = outputEnd
            } else {
                searchOffset = suffixStart + 1
            }
        }
        return matchedLines
    }

    @inline(__always)
    private static func matchesCapitalizedWordWhitespacePrefix(
        bytes: UnsafePointer<UInt8>,
        lineStart: Int,
        suffixStart: Int
    ) -> Bool? {
        var cursor = suffixStart
        var foundWhitespace = false
        while cursor > lineStart {
            let byte = bytes[cursor - 1]
            if byte >= 0x80 { return nil }
            guard isASCIIWhitespace(byte) else { break }
            foundWhitespace = true
            cursor -= 1
        }
        guard foundWhitespace else { return false }

        let lowercaseEnd = cursor
        while cursor > lineStart {
            let byte = bytes[cursor - 1]
            guard byte >= UInt8(ascii: "a"), byte <= UInt8(ascii: "z") else {
                break
            }
            cursor -= 1
        }
        guard cursor < lowercaseEnd, cursor > lineStart else { return false }
        let uppercase = bytes[cursor - 1]
        return uppercase >= UInt8(ascii: "A") && uppercase <= UInt8(ascii: "Z")
    }

    @inline(__always)
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || (byte >= 0x09 && byte <= 0x0D)
    }

    @inline(__always)
    private static func findByte(
        _ bytes: UnsafePointer<UInt8>,
        count: Int,
        byte: UInt8
    ) -> Int? {
        guard count > 0,
              let rawFound = memchr(bytes, Int32(byte), count) else {
            return nil
        }
        let found = UnsafeRawPointer(rawFound).assumingMemoryBound(to: UInt8.self)
        return bytes.distance(to: found)
    }

    @inline(__always)
    private static func findLiteral(
        bytes: UnsafePointer<UInt8>,
        range: Range<Int>,
        literal: [UInt8]
    ) -> Int? {
        guard range.count >= literal.count, let first = literal.first else { return nil }
        let lastStart = range.upperBound - literal.count
        var searchOffset = range.lowerBound
        while searchOffset <= lastStart,
              let rawFound = memchr(
                bytes.advanced(by: searchOffset),
                Int32(first),
                lastStart - searchOffset + 1
              ) {
            let found = UnsafeRawPointer(rawFound).assumingMemoryBound(to: UInt8.self)
            let candidate = bytes.distance(to: found)
            if literalMatches(bytes: bytes, at: candidate, literal: literal) {
                return candidate
            }
            searchOffset = candidate + 1
        }
        return nil
    }

    @inline(__always)
    private static func literalMatches(
        bytes: UnsafePointer<UInt8>,
        at offset: Int,
        literal: [UInt8]
    ) -> Bool {
        for index in literal.indices where bytes[offset + index] != literal[index] {
            return false
        }
        return true
    }

    private static func writeDecimalLine(_ value: Int) -> Bool {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
            var cursor = buffer.count - 1
            buffer[cursor] = UInt8(ascii: "\n")
            var value = value
            repeat {
                cursor -= 1
                buffer[cursor] = UInt8(value % 10) + UInt8(ascii: "0")
                value /= 10
            } while value > 0
            return writeAll(
                buffer.baseAddress!.advanced(by: cursor),
                count: buffer.count - cursor
            )
        }
    }

    private static func writeAll(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let written = write(STDOUT_FILENO, bytes.advanced(by: offset), count - offset)
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    private struct POSIXOutputBuffer {
        private var storage: UnsafeMutablePointer<UInt8>?
        private let capacity: Int
        private var length = 0

        init(capacity: Int) {
            self.capacity = capacity
            storage = .allocate(capacity: capacity)
        }

        mutating func deallocate() {
            storage?.deallocate()
            storage = nil
            length = 0
        }

        mutating func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
            guard count > 0 else { return true }
            if count > capacity {
                return flush() && writeDirect(bytes, count: count)
            }
            if count > capacity - length, !flush() { return false }
            guard let storage else { return false }
            storage.advanced(by: length).update(from: bytes, count: count)
            length += count
            return true
        }

        mutating func writeBytes(_ bytes: [UInt8]) -> Bool {
            return bytes.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return true }
                return write(baseAddress, count: buffer.count)
            }
        }

        mutating func writeByte(_ byte: UInt8) -> Bool {
            guard length < capacity, let storage else {
                var byte = byte
                return withUnsafePointer(to: &byte) { write($0, count: 1) }
            }
            storage[length] = byte
            length += 1
            return true
        }

        mutating func writeDecimal(_ value: Int, terminator: UInt8) -> Bool {
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
                var cursor = buffer.count
                var value = value
                repeat {
                    cursor -= 1
                    buffer[cursor] = UInt8(value % 10) + UInt8(ascii: "0")
                    value /= 10
                } while value > 0
                guard write(buffer.baseAddress!.advanced(by: cursor), count: buffer.count - cursor) else {
                    return false
                }
                return writeByte(terminator)
            }
        }

        mutating func flush() -> Bool {
            guard length > 0 else { return true }
            guard let storage, writeDirect(UnsafePointer(storage), count: length) else {
                return false
            }
            length = 0
            return true
        }

        private func writeDirect(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
            var offset = 0
            while offset < count {
                #if canImport(Glibc)
                let written = Glibc.write(STDOUT_FILENO, bytes.advanced(by: offset), count - offset)
                #else
                let written = Musl.write(STDOUT_FILENO, bytes.advanced(by: offset), count - offset)
                #endif
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
#endif
