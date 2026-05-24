import Darwin
import Foundation

struct HaystackReader {
    enum ReadPath: Equatable {
        case buffered
        case mmap
    }

    static let bufferedChunkSize = 64 * 1024
    static let automaticMmapThreshold = UInt64(16 * 1024)
    static let defaultMaxBufferBytes = 256 * 1024 * 1024

    struct StreamedLine {
        let data: Data
        let terminator: Data
        let absoluteOffset: Int
    }

    static func read(
        _ haystack: Haystack,
        options: RipgrepOptions,
        maxBufferBytes: Int = defaultMaxBufferBytes
    ) throws -> Data {
        let readPath = try selectedPath(forFileAt: haystack.url, options: options)
        switch readPath {
        case .buffered:
            return try readBuffered(fileURL: haystack.url, maxBufferBytes: maxBufferBytes)
        case .mmap:
            do {
                return try readMmap(fileURL: haystack.url)
            } catch {
                guard options.mmapMode != .always else {
                    throw error
                }
                return try readBuffered(fileURL: haystack.url, maxBufferBytes: maxBufferBytes)
            }
        }
    }

    static func readStandardInput(maxBufferBytes: Int = defaultMaxBufferBytes) throws -> Data {
        try readChunks(from: .standardInput, closeWhenDone: false, maxBufferBytes: maxBufferBytes)
    }

    static func streamLines(
        _ haystack: Haystack,
        options: RipgrepOptions,
        maxCarryBytes: Int = defaultMaxBufferBytes,
        body: (StreamedLine, inout Bool) throws -> Void
    ) throws {
        let readPath = try selectedPath(forFileAt: haystack.url, options: options)
        guard readPath == .buffered else {
            throw ReaderError.notBuffered(path: haystack.url.path)
        }
        let handle = try FileHandle(forReadingFrom: haystack.url)
        try streamLines(from: handle, closeWhenDone: true, maxCarryBytes: maxCarryBytes, body: body)
    }

    static func selectedPath(forFileAt fileURL: URL, options: RipgrepOptions) throws -> ReadPath {
        var fileStat = stat()
        let statResult = fileURL.path.withCString { path in
            Darwin.fstatat(AT_FDCWD, path, &fileStat, 0)
        }
        guard statResult == 0 else {
            throw ReaderError.posix(path: fileURL.path, operation: "stat", code: errno)
        }
        return selectedPath(
            fileSize: UInt64(max(0, fileStat.st_size)),
            isRegularFile: isRegular(fileStat.st_mode),
            options: options
        )
    }

    static func selectedPath(fileSize: UInt64, isRegularFile: Bool, options: RipgrepOptions) -> ReadPath {
        switch options.mmapMode {
        case .always:
            return .mmap
        case .never:
            return .buffered
        case .automatic:
            return isRegularFile && fileSize >= automaticMmapThreshold ? .mmap : .buffered
        }
    }

    private static func readBuffered(fileURL: URL, maxBufferBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        return try readChunks(from: handle, closeWhenDone: true, maxBufferBytes: maxBufferBytes)
    }

    private static func readChunks(
        from handle: FileHandle,
        closeWhenDone: Bool,
        maxBufferBytes: Int
    ) throws -> Data {
        defer {
            if closeWhenDone {
                try? handle.close()
            }
        }

        var data = Data()
        while true {
            guard let chunk = try handle.read(upToCount: bufferedChunkSize), !chunk.isEmpty else {
                break
            }
            try append(chunk, to: &data, maxBufferBytes: maxBufferBytes)
        }
        return data
    }

    private static func streamLines(
        from handle: FileHandle,
        closeWhenDone: Bool,
        maxCarryBytes: Int,
        body: (StreamedLine, inout Bool) throws -> Void
    ) throws {
        defer {
            if closeWhenDone {
                try? handle.close()
            }
        }

        var carry = Data()
        var absoluteOffset = 0
        var terminate = false
        while !terminate {
            guard let chunk = try handle.read(upToCount: bufferedChunkSize), !chunk.isEmpty else {
                break
            }
            try append(chunk, to: &carry, maxBufferBytes: maxCarryBytes)

            while !terminate, let newlineIndex = carry.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = Data(carry[..<newlineIndex])
                let lineByteCount = lineData.count + 1
                try body(
                    StreamedLine(
                        data: lineData,
                        terminator: Data([UInt8(ascii: "\n")]),
                        absoluteOffset: absoluteOffset
                    ),
                    &terminate
                )
                carry.removeSubrange(..<carry.index(after: newlineIndex))
                absoluteOffset += lineByteCount
            }
        }

        if !terminate, !carry.isEmpty {
            try body(StreamedLine(data: carry, terminator: Data(), absoluteOffset: absoluteOffset), &terminate)
        }
    }

    private static func append(_ chunk: Data, to data: inout Data, maxBufferBytes: Int) throws {
        let nextSize = data.count + chunk.count
        guard nextSize <= maxBufferBytes else {
            throw ReaderError.bufferLimitExceeded(size: nextSize, limit: maxBufferBytes)
        }
        data.append(chunk)
    }

    private static func readMmap(fileURL: URL) throws -> Data {
        let fd = fileURL.path.withCString { path in
            Darwin.open(path, O_RDONLY)
        }
        guard fd >= 0 else {
            throw ReaderError.posix(path: fileURL.path, operation: "open", code: errno)
        }
        defer { Darwin.close(fd) }

        var fileStat = stat()
        guard Darwin.fstat(fd, &fileStat) == 0 else {
            throw ReaderError.posix(path: fileURL.path, operation: "fstat", code: errno)
        }
        guard isRegular(fileStat.st_mode) else {
            throw ReaderError.notRegular(path: fileURL.path)
        }
        guard fileStat.st_size > 0 else {
            return Data()
        }
        guard UInt64(fileStat.st_size) <= UInt64(Int.max) else {
            throw ReaderError.tooLarge(path: fileURL.path, size: UInt64(fileStat.st_size))
        }

        let length = Int(fileStat.st_size)
        let mapped = Darwin.mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0)
        guard mapped != MAP_FAILED, let mapped else {
            throw ReaderError.posix(path: fileURL.path, operation: "mmap", code: errno)
        }

        return Data(bytesNoCopy: mapped, count: length, deallocator: .custom { pointer, count in
            Darwin.munmap(pointer, count)
        })
    }

    private static func isRegular(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFREG
    }
}

extension HaystackReader {
    enum ReaderError: Error, CustomStringConvertible, Equatable {
        case posix(path: String, operation: String, code: Int32)
        case notRegular(path: String)
        case tooLarge(path: String, size: UInt64)
        case bufferLimitExceeded(size: Int, limit: Int)
        case notBuffered(path: String)

        var description: String {
            switch self {
            case .posix(let path, let operation, let code):
                return "\(path): failed to \(operation): \(String(cString: strerror(code))) (os error \(code))"
            case .notRegular(let path):
                return "\(path): failed to mmap: not a regular file"
            case .tooLarge(let path, let size):
                return "\(path): failed to mmap: file is too large to map (\(size) bytes)"
            case .bufferLimitExceeded(let size, let limit):
                return "haystack size \(size) exceeds buffered limit \(limit); use --mmap or shrink --max-filesize"
            case .notBuffered(let path):
                return "\(path): selected reader is not buffered"
            }
        }
    }
}
