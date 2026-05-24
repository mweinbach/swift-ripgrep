import Foundation
import XCTest

final class ParityHarnessTests: XCTestCase {
    func testMatchesInstalledRipgrepOnSelectedFixtures() throws {
        guard ProcessInfo.processInfo.environment["SWIFT_RIPGREP_PARITY"] == "1" else {
            throw XCTSkip("Set SWIFT_RIPGREP_PARITY=1 to run the installed rg parity harness.")
        }

        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let rustRipgrep = try findInstalledRipgrep(packageRoot: packageRoot)
        let swiftRipgrep = try ensureSwiftRipgrepBinary(packageRoot: packageRoot)

        for parityCase in parityCases() {
            if let reason = parityCase.intentionallySkippedBecause {
                print("Skipping parity case \(parityCase.name): \(reason)")
                continue
            }

            let tempdir = try IsolatedParityDirectory(name: parityCase.name)
            try parityCase.fixture(tempdir.url)

            let arguments = ["--path-separator", "/"] + parityCase.arguments
            let swiftResult = try runProcess(
                executable: swiftRipgrep,
                arguments: arguments,
                currentDirectory: tempdir.url,
                stdin: parityCase.stdin
            )
            let rustResult = try runProcess(
                executable: rustRipgrep,
                arguments: arguments,
                currentDirectory: tempdir.url,
                stdin: parityCase.stdin
            )

            XCTAssertEqual(
                swiftResult.exitCode,
                rustResult.exitCode,
                "exit status mismatch for \(parityCase.name)\n\(renderComparison(swift: swiftResult, rust: rustResult))"
            )
            expectEqualData(
                swiftResult.stdout,
                rustResult.stdout,
                stream: "stdout",
                caseName: parityCase.name
            )
            expectEqualData(
                swiftResult.stderr,
                rustResult.stderr,
                stream: "stderr",
                caseName: parityCase.name
            )
        }
    }
}

private struct ParityCase {
    var name: String
    var fixture: (URL) throws -> Void
    var arguments: [String]
    var stdin: Data?
    var intentionallySkippedBecause: String?

    init(
        name: String,
        fixture: @escaping (URL) throws -> Void,
        arguments: [String],
        stdin: Data? = nil,
        intentionallySkippedBecause: String? = nil
    ) {
        self.name = name
        self.fixture = fixture
        self.arguments = arguments
        self.stdin = stdin
        self.intentionallySkippedBecause = intentionallySkippedBecause
    }
}

private func parityCases() -> [ParityCase] {
    existingParityCases()
        + binaryParityCases()
        + multilineParityCases()
        + jsonParityCases()
        + miscParityCases()
}

private func existingParityCases() -> [ParityCase] {
    [
        ParityCase(
            name: "recursive sorted text search honors ignore files",
            fixture: existingParityFixture,
            arguments: ["--sort", "path", "needle", "."]
        ),
        ParityCase(
            name: "ignored file produces no match",
            fixture: existingParityFixture,
            arguments: ["ignored-only", "."]
        ),
        ParityCase(
            name: "line numbers in multiline fixture",
            fixture: existingParityFixture,
            arguments: ["-n", "line", "multiline.txt"]
        ),
        ParityCase(
            name: "binary searched as text",
            fixture: existingParityFixture,
            arguments: ["-a", "binary", "binary.bin"]
        ),
        ParityCase(
            name: "explicit UTF-16LE decoding",
            fixture: existingParityFixture,
            arguments: ["--encoding", "utf-16le", "hello", "utf16le.txt"]
        ),
        ParityCase(
            name: "multiline search across line terminators",
            fixture: existingParityFixture,
            arguments: ["-U", "--multiline", "two\\nline", "multiline.txt"]
        ),
        ParityCase(
            name: "threaded sorted text search",
            fixture: existingParityFixture,
            arguments: ["--threads", "4", "--sort", "path", "needle", "."]
        ),
        ParityCase(
            name: "single-thread sorted text search",
            fixture: existingParityFixture,
            arguments: ["--threads", "1", "--sort", "path", "needle", "."]
        ),
    ]
}

private func existingParityFixture(in dir: URL) throws {
    try write("needle in one\n", to: "text/one.txt", in: dir)
    try write("needle in two\n", to: "nested/two.txt", in: dir)
    try write("ignored-only\n", to: "ignored.txt", in: dir)
    try write("ignored.txt\n", to: ".ignore", in: dir)
    try write("one line\ntwo line\n", to: "multiline.txt", in: dir)
    try write(Data([0x62, 0x69, 0x6E, 0x61, 0x72, 0x79, 0x00, 0x74, 0x65, 0x78, 0x74, 0x0A]), to: "binary.bin", in: dir)
    try write(Data("hello\n".utf16LittleEndianBytes), to: "utf16le.txt", in: dir)
}

private func binaryParityCases() -> [ParityCase] {
    let hayFixture: (URL) throws -> Void = { dir in
        try write(try binaryHaystack(), to: "hay", in: dir)
    }
    let emptyFixture: (URL) throws -> Void = { _ in }
    return [
        ParityCase(name: "binary::mmap_match_implicit", fixture: hayFixture, arguments: ["--mmap", "-n", "Project Gutenberg EBook", "-g", "hay"]),
        ParityCase(name: "binary::mmap_match_explicit", fixture: hayFixture, arguments: ["--mmap", "-n", "Project Gutenberg EBook", "hay"]),
        ParityCase(name: "binary::mmap_match_near_nul", fixture: hayFixture, arguments: ["--mmap", "-n", "abcdef", "hay"]),
        ParityCase(name: "binary::mmap_match_count", fixture: hayFixture, arguments: ["--mmap", "-c", "Project Gutenberg EBook|Heaven", "hay"]),
        ParityCase(name: "binary::mmap_match_multiple", fixture: hayFixture, arguments: ["--mmap", "-n", "Project Gutenberg EBook|Heaven", "hay"]),
        ParityCase(name: "binary::mmap_binary_flag", fixture: hayFixture, arguments: ["--mmap", "-n", "--binary", "Heaven", "-g", "hay"]),
        ParityCase(name: "binary::mmap_text_flag", fixture: hayFixture, arguments: ["--mmap", "-n", "--text", "Heaven", "-g", "hay"]),
        ParityCase(name: "binary::mmap_after_nul_match", fixture: hayFixture, arguments: ["--mmap", "-n", "medical student", "hay"]),
        ParityCase(name: "binary::after_match1_implicit", fixture: hayFixture, arguments: ["--no-mmap", "-n", "Project Gutenberg EBook", "-g", "hay"]),
        ParityCase(name: "binary::after_match1_explicit", fixture: hayFixture, arguments: ["--no-mmap", "-n", "Project Gutenberg EBook", "hay"]),
        ParityCase(name: "binary::after_match1_stdin", fixture: emptyFixture, arguments: ["--no-mmap", "-n", "Project Gutenberg EBook"], stdin: try? binaryHaystack()),
        ParityCase(name: "binary::after_match1_implicit_binary", fixture: hayFixture, arguments: ["--no-mmap", "-n", "--binary", "Project Gutenberg EBook", "-g", "hay"]),
        ParityCase(name: "binary::after_match1_implicit_text", fixture: hayFixture, arguments: ["--no-mmap", "-n", "--text", "Project Gutenberg EBook", "-g", "hay"]),
        ParityCase(name: "binary::after_match1_explicit_text", fixture: hayFixture, arguments: ["--no-mmap", "-n", "--text", "Project Gutenberg EBook", "hay"]),
        ParityCase(name: "binary::after_match1_implicit_path", fixture: hayFixture, arguments: ["--no-mmap", "-l", "Project Gutenberg EBook", "-g", "hay"]),
        ParityCase(name: "binary::after_match1_implicit_quiet", fixture: hayFixture, arguments: ["--no-mmap", "-q", "Project Gutenberg EBook", "-g", "hay"]),
        ParityCase(name: "binary::after_match1_implicit_count", fixture: hayFixture, arguments: ["--no-mmap", "-c", "Project Gutenberg EBook", "-g", "hay"]),
        ParityCase(name: "binary::after_match1_implicit_count_binary", fixture: hayFixture, arguments: ["--no-mmap", "-c", "--binary", "Project Gutenberg EBook", "-g", "hay"]),
        ParityCase(name: "binary::after_match1_explicit_count", fixture: hayFixture, arguments: ["--no-mmap", "-c", "Project Gutenberg EBook", "hay"]),
        ParityCase(name: "binary::after_match2_implicit", fixture: hayFixture, arguments: ["--no-mmap", "-n", "Project Gutenberg EBook|a medical student", "-g", "hay"]),
        ParityCase(name: "binary::after_match2_implicit_text", fixture: hayFixture, arguments: ["--no-mmap", "-n", "--text", "Project Gutenberg EBook|a medical student", "-g", "hay"]),
        ParityCase(name: "binary::before_match1_implicit", fixture: hayFixture, arguments: ["--no-mmap", "-n", "Heaven", "-g", "hay"]),
        ParityCase(name: "binary::before_match1_explicit", fixture: hayFixture, arguments: ["--no-mmap", "-n", "Heaven", "hay"]),
        ParityCase(name: "binary::before_match1_implicit_binary", fixture: hayFixture, arguments: ["--no-mmap", "-n", "--binary", "Heaven", "-g", "hay"]),
        ParityCase(name: "binary::before_match1_implicit_text", fixture: hayFixture, arguments: ["--no-mmap", "-n", "--text", "Heaven", "-g", "hay"]),
        ParityCase(name: "binary::before_match2_implicit", fixture: hayFixture, arguments: ["--no-mmap", "-n", "a medical student", "-g", "hay"]),
        ParityCase(name: "binary::before_match2_explicit", fixture: hayFixture, arguments: ["--no-mmap", "-n", "a medical student", "hay"]),
        ParityCase(name: "binary::before_match2_implicit_text", fixture: hayFixture, arguments: ["--no-mmap", "-n", "--text", "a medical student", "-g", "hay"]),
        ParityCase(name: "binary::matching_files_inconsistent_with_count_files", fixture: matchingFilesInconsistentFixture, arguments: ["--sort=path", "-l", "cat"]),
        ParityCase(name: "binary::matching_files_inconsistent_with_count_count", fixture: matchingFilesInconsistentFixture, arguments: ["--sort=path", "-c", "cat"]),
        ParityCase(name: "binary::matching_files_inconsistent_with_count_binary", fixture: matchingFilesInconsistentFixture, arguments: ["--sort=path", "-c", "cat", "--binary"]),
        ParityCase(name: "binary::matching_files_inconsistent_with_count_text", fixture: matchingFilesInconsistentFixture, arguments: ["--sort=path", "-c", "cat", "--text"]),
    ]
}

private func miscParityCases() -> [ParityCase] {
    let sherlockFixture: (URL) throws -> Void = { dir in
        try write(SHERLOCK, to: "sherlock", in: dir)
    }
    let fileTypesFixture: (URL) throws -> Void = { dir in
        try write(SHERLOCK, to: "sherlock", in: dir)
        try write("Sherlock", to: "file.py", in: dir)
        try write("Sherlock", to: "file.rs", in: dir)
    }
    let fileTypesNoSherlockFixture: (URL) throws -> Void = { dir in
        try write("Sherlock", to: "file.py", in: dir)
        try write("Sherlock", to: "file.rs", in: dir)
    }
    return [
        ParityCase(name: "misc::single_file", fixture: sherlockFixture, arguments: ["Sherlock", "sherlock"]),
        ParityCase(name: "misc::dir", fixture: sherlockFixture, arguments: ["Sherlock"]),
        ParityCase(name: "misc::line_numbers", fixture: sherlockFixture, arguments: ["-n", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::columns", fixture: sherlockFixture, arguments: ["--column", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::with_filename", fixture: sherlockFixture, arguments: ["-H", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::with_heading", fixture: sherlockFixture, arguments: ["--with-filename", "--heading", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::with_heading_default", fixture: { dir in try write(SHERLOCK, to: "sherlock", in: dir); try write("Sherlock Holmes lives on Baker Street.", to: "foo", in: dir) }, arguments: ["-j1", "--heading", "Sherlock"]),
        ParityCase(name: "misc::inverted", fixture: sherlockFixture, arguments: ["-v", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::inverted_line_numbers", fixture: sherlockFixture, arguments: ["-n", "-v", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::case_insensitive", fixture: sherlockFixture, arguments: ["-i", "sherlock", "sherlock"]),
        ParityCase(name: "misc::word", fixture: sherlockFixture, arguments: ["-w", "as", "sherlock"]),
        ParityCase(name: "misc::word_period", fixture: { dir in try write("...", to: "haystack", in: dir) }, arguments: ["-ow", ".", "haystack"]),
        ParityCase(name: "misc::line", fixture: sherlockFixture, arguments: ["-x", "Watson|and exhibited clearly, with a label attached.", "sherlock"]),
        ParityCase(name: "misc::literal", fixture: { dir in try write(SHERLOCK, to: "sherlock", in: dir); try write("blib\n()\nblab\n", to: "file", in: dir) }, arguments: ["-F", "()", "file"]),
        ParityCase(name: "misc::quiet", fixture: sherlockFixture, arguments: ["-q", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::replace", fixture: sherlockFixture, arguments: ["-r", "FooBar", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::replace_groups", fixture: sherlockFixture, arguments: ["-r", "$2, $1", "([A-Z][a-z]+) ([A-Z][a-z]+)", "sherlock"]),
        ParityCase(name: "misc::replace_named_groups", fixture: sherlockFixture, arguments: ["-r", "$last, $first", "(?P<first>[A-Z][a-z]+) (?P<last>[A-Z][a-z]+)", "sherlock"]),
        ParityCase(name: "misc::replace_with_only_matching", fixture: sherlockFixture, arguments: ["-o", "-r", "$1", #"of (\w+)"#, "sherlock"]),
        ParityCase(name: "misc::file_types", fixture: fileTypesFixture, arguments: ["-t", "rust", "Sherlock"]),
        ParityCase(name: "misc::file_types_all", fixture: { dir in try write(SHERLOCK, to: "sherlock", in: dir); try write("Sherlock", to: "file.py", in: dir) }, arguments: ["-t", "all", "Sherlock"]),
        ParityCase(name: "misc::file_types_negate", fixture: fileTypesNoSherlockFixture, arguments: ["-T", "rust", "Sherlock"]),
        ParityCase(name: "misc::file_types_negate_all", fixture: { dir in try write(SHERLOCK, to: "sherlock", in: dir); try write("Sherlock", to: "file.py", in: dir) }, arguments: ["-T", "all", "Sherlock"]),
        ParityCase(name: "misc::file_type_clear", fixture: fileTypesFixture, arguments: ["--type-clear", "rust", "-t", "rust", "Sherlock"]),
        ParityCase(name: "misc::file_type_add", fixture: { dir in try fileTypesFixture(dir); try write("Sherlock", to: "file.wat", in: dir) }, arguments: ["--type-add", "wat:*.wat", "-t", "wat", "Sherlock"]),
        ParityCase(name: "misc::file_type_add_compose", fixture: { dir in try fileTypesFixture(dir); try write("Sherlock", to: "file.wat", in: dir) }, arguments: ["--type-add", "wat:*.wat", "--type-add", "combo:include:wat,py", "-t", "combo", "Sherlock"]),
        ParityCase(name: "misc::glob", fixture: fileTypesFixture, arguments: ["-g", "*.rs", "Sherlock"]),
        ParityCase(name: "misc::glob_negate", fixture: fileTypesNoSherlockFixture, arguments: ["-g", "!*.rs", "Sherlock"]),
        ParityCase(name: "misc::glob_case_insensitive", fixture: { dir in try write(SHERLOCK, to: "sherlock", in: dir); try write("Sherlock", to: "file.HTML", in: dir) }, arguments: ["--iglob", "*.html", "Sherlock"]),
        ParityCase(name: "misc::glob_case_sensitive", fixture: { dir in try write(SHERLOCK, to: "sherlock", in: dir); try write("Sherlock", to: "file1.HTML", in: dir); try write("Sherlock", to: "file2.html", in: dir) }, arguments: ["--glob", "*.html", "Sherlock"]),
        ParityCase(name: "misc::glob_always_case_insensitive", fixture: { dir in try write(SHERLOCK, to: "sherlock", in: dir); try write("Sherlock", to: "file.HTML", in: dir) }, arguments: ["--glob-case-insensitive", "--glob", "*.html", "Sherlock"]),
        ParityCase(name: "misc::byte_offset_only_matching", fixture: sherlockFixture, arguments: ["-b", "-o", "Sherlock"]),
        ParityCase(name: "misc::count", fixture: sherlockFixture, arguments: ["--count", "Sherlock"]),
        ParityCase(name: "misc::count_matches", fixture: sherlockFixture, arguments: ["--count-matches", "the"]),
        ParityCase(name: "misc::count_matches_inverted", fixture: sherlockFixture, arguments: ["--count-matches", "--invert-match", "Sherlock"]),
        ParityCase(name: "misc::count_matches_via_only", fixture: sherlockFixture, arguments: ["--count", "--only-matching", "the"]),
        ParityCase(name: "misc::include_zero", fixture: sherlockFixture, arguments: ["--count", "--include-zero", "nada"]),
        ParityCase(name: "misc::include_zero_override", fixture: sherlockFixture, arguments: ["--count", "--include-zero", "--no-include-zero", "nada"]),
        ParityCase(name: "misc::files_with_matches", fixture: sherlockFixture, arguments: ["--files-with-matches", "Sherlock"]),
        ParityCase(name: "misc::files_without_match", fixture: { dir in try write(SHERLOCK, to: "sherlock", in: dir); try write("foo", to: "file.py", in: dir) }, arguments: ["--files-without-match", "Sherlock"]),
        ParityCase(name: "misc::after_context", fixture: sherlockFixture, arguments: ["-A", "1", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::after_context_line_numbers", fixture: sherlockFixture, arguments: ["-A", "1", "-n", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::before_context", fixture: sherlockFixture, arguments: ["-B", "1", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::before_context_line_numbers", fixture: sherlockFixture, arguments: ["-B", "1", "-n", "Sherlock", "sherlock"]),
        ParityCase(name: "misc::context", fixture: sherlockFixture, arguments: ["-C", "1", "world|attached", "sherlock"]),
        ParityCase(name: "misc::context_line_numbers", fixture: sherlockFixture, arguments: ["-C", "1", "-n", "world|attached", "sherlock"]),
    ]
}

private let jsonElapsedDivergence = "Rust rg emits real elapsed timings in JSON stats while Swift JSON output is deterministic with zero elapsed fields."

private func jsonParityCases() -> [ParityCase] {
    let sherlockFixture: (URL) throws -> Void = { dir in
        try write(SHERLOCK, to: "sherlock", in: dir)
    }
    let sherlockCRLFFixture: (URL) throws -> Void = { dir in
        try write(SHERLOCK_CRLF, to: "sherlock", in: dir)
    }
    let notUTF8FileFixture: (URL) throws -> Void = { dir in
        try write(Data([0x71, 0x75, 0x75, 0x78, 0xFF, 0x62, 0x61, 0x7A]), to: "foo", in: dir)
    }
    return [
        ParityCase(name: "json::basic", fixture: sherlockFixture, arguments: ["--json", "-B1", "Sherlock Holmes", "sherlock"], intentionallySkippedBecause: jsonElapsedDivergence),
        ParityCase(name: "json::replacement", fixture: sherlockFixture, arguments: ["--json", "-B1", "Sherlock Holmes", "-r", "John Watson", "sherlock"], intentionallySkippedBecause: jsonElapsedDivergence),
        ParityCase(name: "json::quiet_stats", fixture: sherlockFixture, arguments: ["--json", "--quiet", "--stats", "Sherlock Holmes", "sherlock"], intentionallySkippedBecause: jsonElapsedDivergence),
        ParityCase(name: "json::notutf8", fixture: { _ in }, arguments: ["--json", #"(?-u)\xFF"#], intentionallySkippedBecause: "APFS does not support Rust's invalid UTF-8 filename fixture; JSON elapsed fields also differ byte-for-byte."),
        ParityCase(name: "json::notutf8_file", fixture: notUTF8FileFixture, arguments: ["--json", #"(?-u)\xFF"#], intentionallySkippedBecause: jsonElapsedDivergence),
        ParityCase(name: "json::crlf", fixture: sherlockCRLFFixture, arguments: ["--json", "--crlf", #"Sherlock$"#, "sherlock"], intentionallySkippedBecause: jsonElapsedDivergence),
        ParityCase(name: "json::r1095_missing_crlf_default", fixture: { dir in try write("test\r\n", to: "foo", in: dir) }, arguments: ["--json", "test"], intentionallySkippedBecause: jsonElapsedDivergence),
        ParityCase(name: "json::r1095_missing_crlf_flag", fixture: { dir in try write("test\r\n", to: "foo", in: dir) }, arguments: ["--json", "--crlf", "test"], intentionallySkippedBecause: jsonElapsedDivergence),
        ParityCase(name: "json::r1095_crlf_empty_match_default", fixture: { dir in try write("test\r\n\n", to: "foo", in: dir) }, arguments: ["-U", "--json", "\n"], intentionallySkippedBecause: jsonElapsedDivergence),
        ParityCase(name: "json::r1095_crlf_empty_match_flag", fixture: { dir in try write("test\r\n\n", to: "foo", in: dir) }, arguments: ["-U", "--json", "--crlf", "\n"], intentionallySkippedBecause: jsonElapsedDivergence),
        ParityCase(name: "json::r1412_look_behind_match_missing", fixture: { dir in try write("foo\nbar\n", to: "test", in: dir) }, arguments: ["--pcre2", "-U", "--json", "(?<=foo\\n)bar"], intentionallySkippedBecause: jsonElapsedDivergence),
    ]
}

private func multilineParityCases() -> [ParityCase] {
    let sherlockFixture: (URL) throws -> Void = { dir in
        try write(SHERLOCK, to: "sherlock", in: dir)
    }
    let emptyFixture: (URL) throws -> Void = { _ in }
    return [
        ParityCase(name: "multiline::overlap1", fixture: { dir in try write("xxx\nabc\ndefxxxabc\ndefxxx\nxxx", to: "test", in: dir) }, arguments: ["-n", "-U", "abc\ndef", "test"]),
        ParityCase(name: "multiline::overlap2", fixture: { dir in try write("xxx\nabc\ndefabc\ndefxxx\nxxx", to: "test", in: dir) }, arguments: ["-n", "-U", "abc\ndef", "test"]),
        ParityCase(name: "multiline::dot_no_newline", fixture: sherlockFixture, arguments: ["-n", "-U", "of this world.+detective work", "sherlock"]),
        ParityCase(name: "multiline::dot_all", fixture: sherlockFixture, arguments: ["-n", "-U", "--multiline-dotall", "of this world.+detective work", "sherlock"]),
        ParityCase(name: "multiline::only_matching", fixture: sherlockFixture, arguments: ["-n", "-U", "--only-matching", #"Watson|Sherlock\p{Any}+?Holmes"#, "sherlock"]),
        ParityCase(name: "multiline::vimgrep", fixture: sherlockFixture, arguments: ["-n", "-U", "--vimgrep", #"Watson|Sherlock\p{Any}+?Holmes"#, "sherlock"]),
        ParityCase(name: "multiline::stdin", fixture: emptyFixture, arguments: ["-n", "-U", #"of this world\p{Any}+?detective work"#], stdin: Data(SHERLOCK.utf8)),
        ParityCase(name: "multiline::context", fixture: sherlockFixture, arguments: ["-n", "-U", "-C1", #"detective work\p{Any}+?result of luck"#, "sherlock"]),
    ]
}

private func binaryHaystack() throws -> Data {
    let upstream = URL(fileURLWithPath: "/Users/mweinbach/Projects/swift-harness/ripgrep/tests/data/sherlock-nul.txt")
    if FileManager.default.fileExists(atPath: upstream.path) {
        return try Data(contentsOf: upstream)
    }

    var fallback = Data()
    fallback.append(contentsOf: "The Project Gutenberg EBook of A Study In Scarlet, by Arthur Conan Doyle\n".utf8)
    for index in 0..<1_500 {
        fallback.append(contentsOf: "padding line \(index)\n".utf8)
    }
    fallback.append(0)
    fallback.append(contentsOf: "abcdef\n\"No. Heaven knows what the objects of his studies are. But here we\n\"And yet you say he is not a medical student?\"\n".utf8)
    return fallback
}

private func matchingFilesInconsistentFixture(in dir: URL) throws {
    var file1 = "cat here\n"
    for _ in 0..<150_000 {
        file1 += "padding line\n"
    }
    file1 += "\0"
    try write(file1, to: "file1.txt", in: dir)
    try write("cat here", to: "file2.txt", in: dir)
}

private struct ProcessResult {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
}

private final class IsolatedParityDirectory {
    let url: URL

    init(name: String) throws {
        let safeName = String(name.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-ripgrep-parity-\(safeName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func write(_ contents: String, to relativePath: String, in dir: URL) throws {
    try write(Data(contents.utf8), to: relativePath, in: dir)
}

private func write(_ data: Data, to relativePath: String, in dir: URL) throws {
    let fileURL = dir.appendingPathComponent(relativePath, isDirectory: false)
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
}

private func findInstalledRipgrep(packageRoot: URL) throws -> URL {
    let whichResult = try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["which", "rg"],
        currentDirectory: packageRoot
    )
    guard whichResult.exitCode == 0,
          let path = String(data: whichResult.stdout, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .first
    else {
        throw XCTSkip("Could not find installed rg with `which rg`.")
    }
    return URL(fileURLWithPath: String(path))
}

private func ensureSwiftRipgrepBinary(packageRoot: URL) throws -> URL {
    let binary = packageRoot.appendingPathComponent(".build/debug/ripgrep")
    if FileManager.default.isExecutableFile(atPath: binary.path) {
        return binary
    }

    let buildResult = try runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["swift", "build"],
        currentDirectory: packageRoot
    )
    guard buildResult.exitCode == 0 else {
        XCTFail("swift build failed while preparing parity harness:\n\(render(buildResult))")
        throw ParityHarnessError.buildFailed
    }
    return binary
}

private func runProcess(
    executable: URL,
    arguments: [String],
    currentDirectory: URL,
    stdin: Data? = nil
) throws -> ProcessResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "RIPGREP_CONFIG_PATH")
    process.environment = environment

    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    if stdin != nil {
        process.standardInput = input
    }
    process.standardOutput = output
    process.standardError = error

    try process.run()
    if let stdin {
        try input.fileHandleForWriting.write(contentsOf: stdin)
        try input.fileHandleForWriting.close()
    }
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return ProcessResult(
        exitCode: process.terminationStatus,
        stdout: stdout,
        stderr: stderr
    )
}

private func expectEqualData(_ actual: Data, _ expected: Data, stream: String, caseName: String) {
    guard actual != expected else { return }
    XCTFail("""
    \(stream) mismatch for \(caseName)
    --- swift-ripgrep
    \(render(actual))
    --- installed rg
    \(render(expected))
    """)
}

private func renderComparison(swift: ProcessResult, rust: ProcessResult) -> String {
    """
    --- swift-ripgrep
    \(render(swift))
    --- installed rg
    \(render(rust))
    """
}

private func render(_ result: ProcessResult) -> String {
    """
    exit: \(result.exitCode)
    stdout:
    \(render(result.stdout))
    stderr:
    \(render(result.stderr))
    """
}

private func render(_ data: Data) -> String {
    if let text = String(data: data, encoding: .utf8) {
        return text.debugDescription
    }
    return data.base64EncodedString()
}

private enum ParityHarnessError: Error {
    case buildFailed
}

