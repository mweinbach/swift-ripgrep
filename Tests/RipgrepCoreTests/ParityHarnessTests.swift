import Foundation
import XCTest

final class ParityHarnessTests: XCTestCase {
    func testMatchesRustRipgrepOnSelectedFixtures() throws {
        guard ProcessInfo.processInfo.environment["SWIFT_RIPGREP_PARITY"] == "1" else {
            throw XCTSkip("Set SWIFT_RIPGREP_PARITY=1 to run the Rust rg parity harness.")
        }

        let packageRoot = ripgrepPackageRootURL()
        let rustRipgrep = try findRustRipgrep(packageRoot: packageRoot)
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
                normalize(swiftResult.stdout, for: parityCase),
                normalize(rustResult.stdout, for: parityCase),
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
        + featureParityCases()
        + regressionParityCases()
        + compressedInputParityCases()
}

private func compressedInputParityCases() -> [ParityCase] {
    // Compressed-input formats `rg` decompresses through external tools when
    // `--search-zip` (alias `-z`) is set. Each fixture writes the SHERLOCK
    // haystack as a real compressed file using the system's compressor.
    // If the system tool isn't available the case is skipped (Rust `rg`
    // would also fail to decompress without the tool, so parity isn't
    // possible anyway).
    let formats: [(name: String, ext: String, tool: String, encodeArgs: [String])] = [
        ("gz",  ".gz",  "gzip",  ["-c"]),
        ("bz2", ".bz2", "bzip2", ["-c"]),
        ("xz",  ".xz",  "xz",    ["-c"]),
        ("lzma", ".lzma", "xz",   ["--format=lzma", "-c"]),
        ("br",  ".br",  "brotli", ["-c"]),
        ("zst", ".zst", "zstd",  ["-q", "-c"]),
        ("lz4", ".lz4", "lz4",   ["-q", "-c"]),
    ]
    var cases: [ParityCase] = []
    for format in formats {
        let toolPath = locateTool(format.tool)
        let basename = "sherlock" + format.ext
        let skip = (toolPath == nil)
            ? "system tool `\(format.tool)` is not available on PATH"
            : nil
        let fixture: (URL) throws -> Void = { dir in
            guard let tool = toolPath else { return }
            try writeCompressed(SHERLOCK, to: basename, in: dir, tool: tool, arguments: format.encodeArgs)
        }
        cases.append(ParityCase(
            name: "searchzip::\(format.name)_match",
            fixture: fixture,
            arguments: ["--search-zip", "-n", "Sherlock", basename],
            intentionallySkippedBecause: skip
        ))
        cases.append(ParityCase(
            name: "searchzip::\(format.name)_count",
            fixture: fixture,
            arguments: ["--search-zip", "-c", "Sherlock", basename],
            intentionallySkippedBecause: skip
        ))
        cases.append(ParityCase(
            name: "searchzip::\(format.name)_files_with_matches",
            fixture: fixture,
            arguments: ["--search-zip", "-l", "Sherlock", basename],
            intentionallySkippedBecause: skip
        ))
    }
    return cases
}

private func locateTool(_ name: String) -> URL? {
    // PATH lookup; mirrors `which <name>` without spawning a subshell.
    guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else {
        return nil
    }
    for directory in pathValue.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func writeCompressed(
    _ contents: String,
    to relativePath: String,
    in dir: URL,
    tool: URL,
    arguments: [String]
) throws {
    let destination = dir.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let process = Process()
    process.executableURL = tool
    process.arguments = arguments

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()

    let inputHandle = stdin.fileHandleForWriting
    try inputHandle.write(contentsOf: Data(contents.utf8))
    try inputHandle.close()

    let compressed = stdout.fileHandleForReading.readDataToEndOfFile()
    _ = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "ParityHarness",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(tool.lastPathComponent) exited with \(process.terminationStatus)"]
        )
    }

    try compressed.write(to: destination, options: .atomic)
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

private func regressionParityCases() -> [ParityCase] {
    let sherlockFixture: (URL) throws -> Void = { dir in try write(SHERLOCK, to: "sherlock", in: dir) }
    let r156Text = """
#parse('widgets/foo_bar_macros.vm')
#parse ( 'widgets/mobile/foo_bar_macros.vm' )
#parse ("widgets/foobarhiddenformfields.vm")
#parse ( "widgets/foo_bar_legal.vm" )
#include( 'widgets/foo_bar_tips.vm' )
#include('widgets/mobile/foo_bar_macros.vm')
#include ("widgets/mobile/foo_bar_resetpw.vm")
#parse('widgets/foo-bar-macros.vm')
#parse ( 'widgets/mobile/foo-bar-macros.vm' )
#parse ("widgets/foo-bar-hiddenformfields.vm")
#parse ( "widgets/foo-bar-legal.vm" )
#include( 'widgets/foo-bar-tips.vm' )
#include('widgets/mobile/foo-bar-macros.vm')
#include ("widgets/mobile/foo-bar-resetpw.vm")
"""
    return [
        ParityCase(name: "regression::r16", fixture: { dir in try createDirectory(".git", in: dir); try write("ghi/", to: ".gitignore", in: dir); try write("xyz", to: "ghi/toplevel.txt", in: dir); try write("xyz", to: "def/ghi/subdir.txt", in: dir) }, arguments: ["xyz"]),
        ParityCase(name: "regression::r25", fixture: { dir in try createDirectory(".git", in: dir); try write("/llvm/", to: ".gitignore", in: dir); try write("test", to: "src/llvm/foo", in: dir) }, arguments: ["test"]),
        ParityCase(name: "regression::r30", fixture: { dir in try write("vendor/**\n!vendor/manifest", to: ".gitignore", in: dir); try write("test", to: "vendor/manifest", in: dir) }, arguments: ["test"]),
        ParityCase(name: "regression::r49", fixture: { dir in try write("foo/bar", to: ".gitignore", in: dir); try write("test", to: "test/foo/bar/baz", in: dir) }, arguments: ["xyz"]),
        ParityCase(name: "regression::r50", fixture: { dir in try write("XXX/YYY/", to: ".gitignore", in: dir); try write("test", to: "abc/def/XXX/YYY/bar", in: dir); try write("test", to: "ghi/XXX/YYY/bar", in: dir) }, arguments: ["xyz"]),
        ParityCase(name: "regression::r64", fixture: { dir in try write("", to: "dir/abc", in: dir); try write("", to: "foo/abc", in: dir) }, arguments: ["--files", "foo"]),
        ParityCase(name: "regression::r65", fixture: { dir in try createDirectory(".git", in: dir); try write("a/", to: ".gitignore", in: dir); try write("xyz", to: "a/foo", in: dir); try write("xyz", to: "a/bar", in: dir) }, arguments: ["xyz"]),
        ParityCase(name: "regression::r67", fixture: { dir in try createDirectory(".git", in: dir); try write("/*\n!/dir", to: ".gitignore", in: dir); try write("test", to: "foo/bar", in: dir); try write("test", to: "dir/bar", in: dir) }, arguments: ["test"]),
        ParityCase(name: "regression::r87", fixture: { dir in try createDirectory(".git", in: dir); try write("foo\n**no-vcs**", to: ".gitignore", in: dir); try write("test", to: "foo", in: dir) }, arguments: ["test"]),
        ParityCase(name: "regression::r90", fixture: { dir in try createDirectory(".git", in: dir); try write("!.foo", to: ".gitignore", in: dir); try write("test", to: ".foo", in: dir) }, arguments: ["test"]),
        ParityCase(name: "regression::r93", fixture: { dir in try write("192.168.1.1", to: "foo", in: dir) }, arguments: ["(\\d{1,3}\\.){3}\\d{1,3}"]),
        ParityCase(name: "regression::r99", fixture: { dir in try write("test", to: "foo1", in: dir); try write("zzz", to: "foo2", in: dir); try write("test", to: "bar", in: dir) }, arguments: ["-j1", "--heading", "test"]),
        ParityCase(name: "regression::r105_part1", fixture: { dir in try write("zztest", to: "foo", in: dir) }, arguments: ["--vimgrep", "test"]),
        ParityCase(name: "regression::r105_part2", fixture: { dir in try write("zztest", to: "foo", in: dir) }, arguments: ["--column", "test"]),
        ParityCase(name: "regression::r127", fixture: { dir in try createDirectory(".git", in: dir); try write("foo/sherlock\n", to: ".gitignore", in: dir); try write(SHERLOCK, to: "foo/sherlock", in: dir); try write(SHERLOCK, to: "foo/watson", in: dir) }, arguments: ["Sherlock"]),
        ParityCase(name: "regression::r128", fixture: { dir in try write(Data([0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x0b,0x0a,0x0b,0x0a,0x0b,0x0a,0x0b,0x0a,0x78]), to: "foo", in: dir) }, arguments: ["-n", "x"]),
        ParityCase(name: "regression::r156", fixture: { dir in try write(r156Text, to: "testcase.txt", in: dir) }, arguments: ["-N", "#(?:parse|include)\\s*\\(\\s*(?:\"|')[./A-Za-z_-]+(?:\"|')", "testcase.txt"]),
        ParityCase(name: "regression::r184", fixture: { dir in try write(".*", to: ".gitignore", in: dir); try write("test", to: "foo/bar/baz", in: dir) }, arguments: ["test"]),
        ParityCase(name: "regression::r199", fixture: { dir in try write("tEsT", to: "foo", in: dir) }, arguments: ["--smart-case", "\\btest\\b"]),
        ParityCase(name: "regression::r206", fixture: { dir in try write("test", to: "foo/bar.txt", in: dir) }, arguments: ["test", "-g", "*.txt"]),
        ParityCase(name: "regression::r228", fixture: { dir in try createDirectory("foo", in: dir) }, arguments: ["--ignore-file", "foo", "test"]),
        ParityCase(name: "regression::r229", fixture: { dir in try write("economie", to: "foo", in: dir) }, arguments: ["-S", "[E]conomie"]),
        ParityCase(name: "regression::r251", fixture: { dir in try write("привет\nПривет\nПрИвЕт", to: "foo", in: dir) }, arguments: ["-i", "привет"]),
        ParityCase(name: "regression::r270", fixture: { dir in try write("-test", to: "foo", in: dir) }, arguments: ["-e", "-test"]),
        ParityCase(name: "regression::r279", fixture: { dir in try write("test", to: "foo", in: dir) }, arguments: ["-q", "test"]),
        ParityCase(name: "regression::r391", fixture: { dir in try createDirectory(".git", in: dir); try write("", to: "lock", in: dir); try write("", to: "bar.py", in: dir); try write("", to: ".git/packed-refs", in: dir); try write("", to: ".git/description", in: dir) }, arguments: ["--no-ignore", "--hidden", "--follow", "--files", "--glob", "!{.git,node_modules,plugged}/**", "--glob", "*.{js,json,php,md,styl,scss,sass,pug,html,config,py,cpp,c,go,hs}"]),
        ParityCase(name: "regression::r405", fixture: { dir in try write("test", to: "foo/bar/file1.txt", in: dir); try write("test", to: "bar/foo/file2.txt", in: dir) }, arguments: ["-g", "!/foo/**", "test"]),
        ParityCase(name: "regression::r451_only_matching_as_in_issue", fixture: { dir in try write("1 2 3\n", to: "digits.txt", in: dir) }, arguments: ["--only-matching", "[0-9]+", "digits.txt"]),
        ParityCase(name: "regression::r451_only_matching", fixture: { dir in try write("1 2 3\n123\n", to: "digits.txt", in: dir) }, arguments: ["--only-matching", "--column", "[0-9]", "digits.txt"]),
        ParityCase(name: "regression::r483_matching_no_stdout", fixture: { dir in try write("", to: "file.py", in: dir) }, arguments: ["--quiet", "--files", "--glob", "*.py"]),
        ParityCase(name: "regression::r483_non_matching_exit_code", fixture: { dir in try write("", to: "file.rs", in: dir) }, arguments: ["--quiet", "--files", "--glob", "*.py"]),
        ParityCase(name: "regression::r493", fixture: { dir in try write("peshwaship 're seminomata", to: "input.txt", in: dir) }, arguments: ["-o", "\\b 're \\b", "input.txt"]),
        ParityCase(name: "regression::r506_word_not_parenthesized", fixture: { dir in try write("min minimum amin\nmax maximum amax", to: "wb.txt", in: dir) }, arguments: ["-w", "-o", "min|max", "wb.txt"]),
        ParityCase(name: "regression::r553_switch_once", fixture: sherlockFixture, arguments: ["-i", "sherlock"]),
        ParityCase(name: "regression::r553_switch_twice", fixture: sherlockFixture, arguments: ["-i", "-i", "sherlock"]),
        ParityCase(name: "regression::r553_flag_c1", fixture: sherlockFixture, arguments: ["-C", "1", "world|attached", "sherlock"]),
        ParityCase(name: "regression::r553_flag_c0", fixture: sherlockFixture, arguments: ["-C", "0", "world|attached", "sherlock"]),
        ParityCase(name: "regression::r568_leading_hyphen_e", fixture: { dir in try write("foo bar -baz\n", to: "file", in: dir) }, arguments: ["-e-baz", "-e", "-baz", "file"]),
        ParityCase(name: "regression::r568_leading_hyphen_rni", fixture: { dir in try write("foo bar -baz\n", to: "file", in: dir) }, arguments: ["-rni", "bar", "file"]),
        ParityCase(name: "regression::r568_leading_hyphen_replacement", fixture: { dir in try write("foo bar -baz\n", to: "file", in: dir) }, arguments: ["-r", "-n", "-i", "bar", "file"]),
        ParityCase(name: "regression::r693_context_in_contextless_mode", fixture: { dir in try write("xyz\n", to: "foo", in: dir); try write("xyz\n", to: "bar", in: dir) }, arguments: ["-C1", "-c", "--sort-files", "xyz"]),
        ParityCase(name: "regression::r807", fixture: { dir in try createDirectory(".git", in: dir); try write(".a/b", to: ".gitignore", in: dir); try write("test", to: ".a/b/file", in: dir); try write("test", to: ".a/c/file", in: dir) }, arguments: ["--hidden", "test"]),
        ParityCase(name: "regression::r829_original", fixture: { dir in try write("/a/b", to: ".ignore", in: dir); try write("Sample text", to: "a/b/test.txt", in: dir) }, arguments: ["Sample"]),
        ParityCase(name: "regression::r829_2731_root", fixture: { dir in try write("build/\n!/some_dir/build/", to: ".ignore", in: dir); try write("string", to: "some_dir/build/foo", in: dir) }, arguments: ["-l", "string"]),
        ParityCase(name: "regression::r900", fixture: { dir in try write(SHERLOCK, to: "sherlock", in: dir); try write("", to: "pat", in: dir) }, arguments: ["-fpat", "sherlock"]),
        ParityCase(name: "regression::r1064", fixture: { dir in try write("abc", to: "input", in: dir) }, arguments: ["a(.*c)"]),
        ParityCase(name: "regression::r1098", fixture: { dir in try createDirectory(".git", in: dir); try write("a**b", to: ".gitignore", in: dir); try write("test", to: "afoob", in: dir) }, arguments: ["test"]),
        ParityCase(name: "regression::r1130_files_with_matches", fixture: { dir in try write("test", to: "foo", in: dir) }, arguments: ["--files-with-matches", "test", "foo"]),
        ParityCase(name: "regression::r1130_files_without_match", fixture: { dir in try write("test", to: "foo", in: dir) }, arguments: ["--files-without-match", "nada", "foo"]),
        ParityCase(name: "regression::r1159_invalid_flag", fixture: { _ in }, arguments: ["--wat"]),
        ParityCase(name: "regression::r1203_reverse_suffix_literal_short", fixture: { dir in try write("153.230000\n", to: "test", in: dir) }, arguments: [#"\d\d\d00"#, "test"]),
        ParityCase(name: "regression::r1203_reverse_suffix_literal_long", fixture: { dir in try write("153.230000\n", to: "test", in: dir) }, arguments: [#"\d\d\d000"#, "test"]),
        ParityCase(name: "regression::r1223_no_dir_check_for_default_path", fixture: { dir in try createDirectory("-", in: dir); try write("{}\n", to: "a.json", in: dir); try write("some text\n", to: "a.txt", in: dir) }, arguments: ["a"], stdin: Data("a.json\na.txt\n".utf8)),
        ParityCase(name: "regression::r1259_pattern_file_without_trailing_newline", fixture: { dir in try write("[foo]", to: "patterns-nonl", in: dir); try write("fz\n", to: "test", in: dir) }, arguments: ["-f", "patterns-nonl", "test"]),
        ParityCase(name: "regression::r1259_pattern_file_with_trailing_newline", fixture: { dir in try write("[foo]\n", to: "patterns-nl", in: dir); try write("fz\n", to: "test", in: dir) }, arguments: ["-f", "patterns-nl", "test"]),
        ParityCase(name: "regression::r1311_multi_line_term_replace", fixture: { dir in try write("hello\nworld\n", to: "input", in: dir) }, arguments: ["-U", "-r?", "-n", "\n", "input"]),
        ParityCase(name: "regression::r1334_zero_patterns", fixture: { dir in try write("", to: "zero-patterns", in: dir); try write("one\ntwo\nthree\n", to: "haystack", in: dir) }, arguments: ["-f", "zero-patterns", "haystack"]),
        ParityCase(name: "regression::r1334_one_empty_pattern", fixture: { dir in try write("\n", to: "one-pattern", in: dir); try write("one\ntwo\nthree\n", to: "haystack", in: dir) }, arguments: ["-f", "one-pattern", "haystack"]),
        ParityCase(name: "regression::r1334_invert_zero_patterns", fixture: { dir in try write("", to: "zero-patterns", in: dir); try write("one\ntwo\nthree\n", to: "haystack", in: dir) }, arguments: ["-v", "-f", "zero-patterns", "haystack"]),
        ParityCase(name: "regression::r1638_utf8_bom_column", fixture: { dir in try write(Data([0xEF, 0xBB, 0xBF, 0x78]), to: "foo", in: dir) }, arguments: ["--column", "x"]),
        ParityCase(name: "regression::r1739_replacement_lineterm_match", fixture: { dir in try write("a\n", to: "test", in: dir) }, arguments: [#"-r${0}f"#, #".*"#, "test"]),
        ParityCase(name: "regression::r1757_ignore_relative_root", fixture: { dir in try write("rust/target\n", to: ".ignore", in: dir); try write("needle", to: "rust/source.rs", in: dir); try write("needle", to: "rust/target/rustdoc-output.html", in: dir) }, arguments: ["--files-with-matches", "needle", "rust"]),
        ParityCase(name: "regression::r1757_ignore_dot_relative_root", fixture: { dir in try write("rust/target\n", to: ".ignore", in: dir); try write("needle", to: "rust/source.rs", in: dir); try write("needle", to: "rust/target/rustdoc-output.html", in: dir) }, arguments: ["--files-with-matches", "needle", "./rust"]),
        ParityCase(name: "regression::r2480_capture_group_replacement", fixture: { dir in try write("FooBar\n", to: "file", in: dir) }, arguments: ["-e", "Fo(oB)a(r)", "--replace", "${0}_${1}_${2}${3}", "file"]),
        ParityCase(name: "regression::r2480_case_flag_does_not_leak_on_match", fixture: { dir in try write("FooBar\n", to: "file", in: dir) }, arguments: ["--only-matching", "-e", "(?i)foo", "-e", "bar", "file"]),
        ParityCase(name: "regression::r2480_case_flag_does_not_leak_on_mismatch", fixture: { dir in try write("FooBar\n", to: "file", in: dir) }, arguments: ["--only-matching", "-e", "(?i)notfoo", "-e", "bar", "file"]),
        ParityCase(name: "regression::r2574_ascii_word_domain", fixture: { dir in try write("some.domain.com\nsome.domain.com/x\n", to: "haystack", in: dir) }, arguments: ["--no-filename", "--no-unicode", "-w", "-o", #"(\w+\.)*domain\.(\w+)"#, "haystack"]),
    ]
}

private func featureParityCases() -> [ParityCase] {
    let sherlockFixture: (URL) throws -> Void = { dir in try write(SHERLOCK, to: "sherlock", in: dir) }
    let crlfFixture: (URL) throws -> Void = { dir in try write(SHERLOCK_CRLF, to: "sherlock", in: dir) }
    let sortingFixture: (URL) throws -> Void = { dir in
        try write("test", to: "foo", in: dir)
        try write("test", to: "abc", in: dir)
        try write("test", to: "zoo", in: dir)
        try write("test", to: "bar", in: dir)
    }
    let passthruFixture: (URL) throws -> Void = { dir in
        try write("\nfoo\nbar\nfoobar\n\nbaz\n", to: "file", in: dir)
        try write("foo\nbar\n", to: "patterns", in: dir)
    }
    let greekScriptFixture: (URL) throws -> Void = { dir in
        try write("latin\nπ alpha\n", to: "a.txt", in: dir)
        try write("micro µ\nomega Ω\n", to: "nested/b.txt", in: dir)
        try write("plain\n", to: "nested/c.txt", in: dir)
    }
    let trimSherlock = """
zzz
    For the Doctor Watsons of this world, as opposed to the Sherlock
  Holmeses, success in the province of detective work must always
	be, to a very large extent, the result of luck. Sherlock Holmes
     can extract a clew from a wisp of straw or a flake of cigar ash;
but Doctor Watson has to have it taken out for him and dusted,
 and exhibited clearly, with a label attached.
"""
    return [
        ParityCase(name: "feature::f1_sjis", fixture: { dir in try write(Data([0x84, 0x59, 0x84, 0x75, 0x84, 0x82, 0x84, 0x7C, 0x84, 0x80, 0x84, 0x7B, 0x20, 0x84, 0x56, 0x84, 0x80, 0x84, 0x7C, 0x84, 0x7D, 0x84, 0x83]), to: "foo", in: dir) }, arguments: ["-Esjis", "Шерлок Холмс"]),
        ParityCase(name: "feature::f1_utf16_auto", fixture: { dir in try write(Data([0xff, 0xfe, 0x28, 0x04, 0x35, 0x04, 0x40, 0x04, 0x3b, 0x04, 0x3e, 0x04, 0x3a, 0x04, 0x20, 0x00, 0x25, 0x04, 0x3e, 0x04, 0x3b, 0x04, 0x3c, 0x04, 0x41, 0x04]), to: "foo", in: dir) }, arguments: ["Шерлок Холмс"]),
        ParityCase(name: "feature::f1_utf16_explicit", fixture: { dir in try write(Data([0xff, 0xfe, 0x28, 0x04, 0x35, 0x04, 0x40, 0x04, 0x3b, 0x04, 0x3e, 0x04, 0x3a, 0x04, 0x20, 0x00, 0x25, 0x04, 0x3e, 0x04, 0x3b, 0x04, 0x3c, 0x04, 0x41, 0x04]), to: "foo", in: dir) }, arguments: ["-Eutf-16le", "Шерлок Холмс"]),
        ParityCase(name: "feature::f1_eucjp", fixture: { dir in try write(Data([0xa7, 0xba, 0xa7, 0xd6, 0xa7, 0xe2, 0xa7, 0xdd, 0xa7, 0xe0, 0xa7, 0xdc, 0x20, 0xa7, 0xb7, 0xa7, 0xe0, 0xa7, 0xdd, 0xa7, 0xde, 0xa7, 0xe3]), to: "foo", in: dir) }, arguments: ["-Eeuc-jp", "Шерлок Холмс"]),
        ParityCase(name: "feature::f1_gb18030_plane2", fixture: { dir in try write(Data([0x95, 0x32, 0x83, 0x37]), to: "foo", in: dir) }, arguments: ["-Egb18030", "𠀋"]),
        ParityCase(name: "feature::f1_big5_hkscs_via_big5", fixture: { dir in try write(Data([0x88, 0x57]), to: "foo", in: dir) }, arguments: ["-Ebig5", "Á"]),
        ParityCase(name: "feature::f1_big5_hkscs_alias", fixture: { dir in try write(Data([0x88, 0x57]), to: "foo", in: dir) }, arguments: ["-Ebig5-hkscs", "Á"]),
        ParityCase(name: "feature::f1_euckr", fixture: { dir in try write(Data([0xc7, 0xd1, 0xb1, 0xb9]), to: "foo", in: dir) }, arguments: ["-Eeuc-kr", "한국"]),
        ParityCase(name: "feature::f1_unknown_encoding", fixture: { _ in }, arguments: ["-Efoobar"]),
        ParityCase(name: "feature::f1_replacement_encoding", fixture: { _ in }, arguments: ["-Ecsiso2022kr"]),
        ParityCase(name: "feature::f7", fixture: { dir in try write(SHERLOCK, to: "sherlock", in: dir); try write("Sherlock\nHolmes", to: "pat", in: dir) }, arguments: ["-fpat", "sherlock"]),
        ParityCase(name: "feature::f7_stdin", fixture: sherlockFixture, arguments: ["-f-"], stdin: Data("Sherlock".utf8)),
        ParityCase(name: "feature::f20_no_filename", fixture: sherlockFixture, arguments: ["--no-filename", "Sherlock"]),
        ParityCase(name: "feature::f34_only_matching", fixture: sherlockFixture, arguments: ["-o", "Sherlock"]),
        ParityCase(name: "feature::f34_only_matching_line_column", fixture: sherlockFixture, arguments: ["-o", "--column", "-n", "Sherlock"]),
        ParityCase(name: "feature::greek_script_recursive_lines", fixture: greekScriptFixture, arguments: ["--sort", "path", "-n", #"\p{Greek}"#, "."]),
        ParityCase(name: "feature::greek_script_recursive_ignore_case_lines", fixture: greekScriptFixture, arguments: ["--sort", "path", "-n", "-i", #"\p{Greek}"#, "."]),
        ParityCase(name: "feature::f45_precedence_with_others", fixture: { dir in try write("*.log", to: ".not-an-ignore", in: dir); try write("!imp.log", to: ".ignore", in: dir); try write("test", to: "imp.log", in: dir); try write("test", to: "wat.log", in: dir) }, arguments: ["--ignore-file", ".not-an-ignore", "test"]),
        ParityCase(name: "feature::f45_precedence_internal", fixture: { dir in try write("*.log", to: ".not-an-ignore1", in: dir); try write("!imp.log", to: ".not-an-ignore2", in: dir); try write("test", to: "imp.log", in: dir); try write("test", to: "wat.log", in: dir) }, arguments: ["--ignore-file", ".not-an-ignore1", "--ignore-file", ".not-an-ignore2", "test"]),
        ParityCase(name: "feature::f68_no_ignore_vcs", fixture: { dir in try createDirectory(".git", in: dir); try write("foo", to: ".gitignore", in: dir); try write("bar", to: ".ignore", in: dir); try write("test", to: "foo", in: dir); try write("test", to: "bar", in: dir) }, arguments: ["--no-ignore-vcs", "test"]),
        ParityCase(name: "feature::f70_smart_case", fixture: sherlockFixture, arguments: ["-S", "sherlock"]),
        ParityCase(name: "feature::f89_files_with_matches", fixture: sherlockFixture, arguments: ["--null", "--files-with-matches", "Sherlock"]),
        ParityCase(name: "feature::f89_files_without_match", fixture: { dir in try write(SHERLOCK, to: "sherlock", in: dir); try write("foo", to: "file.py", in: dir) }, arguments: ["--null", "--files-without-match", "Sherlock"]),
        ParityCase(name: "feature::f89_count", fixture: sherlockFixture, arguments: ["--null", "--count", "Sherlock"]),
        ParityCase(name: "feature::f89_files", fixture: sherlockFixture, arguments: ["--null", "--files"]),
        ParityCase(name: "feature::f89_match", fixture: sherlockFixture, arguments: ["--null", "-C1", "Sherlock"]),
        ParityCase(name: "feature::f109_max_depth", fixture: { dir in try write("far", to: "one/pass", in: dir); try write("far", to: "one/too/many", in: dir) }, arguments: ["--maxdepth", "2", "far"]),
        ParityCase(name: "feature::f109_case_sensitive_part1", fixture: { dir in try write("tEsT", to: "foo", in: dir) }, arguments: ["--smart-case", "--case-sensitive", "test"]),
        ParityCase(name: "feature::f109_case_sensitive_part2", fixture: { dir in try write("tEsT", to: "foo", in: dir) }, arguments: ["--ignore-case", "--case-sensitive", "test"]),
        ParityCase(name: "feature::f129_matches", fixture: { dir in try write("test\ntest abcdefghijklmnopqrstuvwxyz test", to: "foo", in: dir) }, arguments: ["-M26", "test"]),
        ParityCase(name: "feature::f129_context", fixture: { dir in try write("test\nabcdefghijklmnopqrstuvwxyz", to: "foo", in: dir) }, arguments: ["-M20", "-C1", "test"]),
        ParityCase(name: "feature::f129_replace", fixture: { dir in try write("test\ntest abcdefghijklmnopqrstuvwxyz test", to: "foo", in: dir) }, arguments: ["-M26", "-rfoo", "test"]),
        ParityCase(name: "feature::f159_max_count", fixture: { dir in try write("test\ntest", to: "foo", in: dir) }, arguments: ["-m1", "test"]),
        ParityCase(name: "feature::f159_max_count_zero", fixture: { dir in try write("test\ntest", to: "foo", in: dir) }, arguments: ["-m0", "test"]),
        ParityCase(name: "feature::f243_column_line", fixture: { dir in try write("test", to: "foo", in: dir) }, arguments: ["--column", "test"]),
        ParityCase(name: "feature::f263_sort_files", fixture: sortingFixture, arguments: ["--sort-files", "test"]),
        ParityCase(name: "feature::f263_sort_files_reverse", fixture: sortingFixture, arguments: ["--sortr=path", "test"]),
        ParityCase(name: "feature::f275_pathsep", fixture: { dir in try write("test", to: "foo/bar", in: dir) }, arguments: ["test", "--path-separator", "Z"]),
        ParityCase(name: "feature::f362_dfa_size_limit", fixture: sherlockFixture, arguments: ["--dfa-size-limit", "10", "For\\s", "sherlock"]),
        ParityCase(name: "feature::f362_exceeds_regex_size_limit", fixture: { _ in }, arguments: ["--regex-size-limit", "10K", "[0-9]\\w+"]),
        ParityCase(name: "feature::f416_crlf", fixture: crlfFixture, arguments: ["--crlf", #"Sherlock$"#, "sherlock"]),
        ParityCase(name: "feature::f416_crlf_multiline", fixture: crlfFixture, arguments: ["--crlf", "-U", #"Sherlock$"#, "sherlock"]),
        ParityCase(name: "feature::f416_crlf_only_matching", fixture: crlfFixture, arguments: ["--crlf", "-o", #"Sherlock$"#, "sherlock"]),
        ParityCase(name: "feature::f419_zero_as_shortcut_for_null", fixture: sherlockFixture, arguments: ["-0", "--count", "Sherlock"]),
        ParityCase(name: "feature::f740_passthru_single", fixture: passthruFixture, arguments: ["-n", "--passthru", "foo", "file"]),
        ParityCase(name: "feature::f740_passthru_multiple_e", fixture: passthruFixture, arguments: ["-n", "--passthru", "-e", "foo", "-e", "bar", "file"]),
        ParityCase(name: "feature::f740_passthru_multiple_f", fixture: passthruFixture, arguments: ["-n", "--passthru", "-f", "patterns", "file"]),
        ParityCase(name: "feature::f740_passthru_count_override", fixture: passthruFixture, arguments: ["-n", "--passthru", "-c", "foo", "file"]),
        ParityCase(name: "feature::f740_passthru_only_matching", fixture: passthruFixture, arguments: ["-n", "--passthru", "-o", "foo", "file"]),
        ParityCase(name: "feature::f740_passthru_replace", fixture: passthruFixture, arguments: ["-n", "--passthru", "-r", "wat", "foo", "file"]),
        ParityCase(name: "feature::f917_trim", fixture: { dir in try write(trimSherlock, to: "sherlock", in: dir) }, arguments: ["-n", "-B1", "-A2", "--trim", "Holmeses", "sherlock"]),
        ParityCase(name: "feature::f917_trim_match", fixture: { dir in try write(trimSherlock, to: "sherlock", in: dir) }, arguments: ["-n", "-B1", "-A2", "--trim", "\\s+Holmeses", "sherlock"]),
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
    let caseInsensitiveASCIIProofFixture: (URL) throws -> Void = { dir in
        try write("alpha\nNeedle here\nplain tail\n", to: "ascii", in: dir)
    }
    let asciiFixedClassFixture: (URL) throws -> Void = { dir in
        try write("prefix Abcdefghi123 middle Zbcdefghi999 suffix\n", to: "match.txt", in: dir)
        try write("Abcdefgh123\nabcdefghi123\nAbcdefghi12x\n", to: "miss.txt", in: dir)
    }
    let asciiFixedClassMaxCountFixture: (URL) throws -> Void = { dir in
        try write("""
        one Abcdefghi123 two Zbcdefghi999
        three Ybcdefghi555
        """, to: "max.txt", in: dir)
    }
    let asciiFixedClassCRLFFixture: (URL) throws -> Void = { dir in
        try write(
            Data("crlf Abcdefghi123 more Zbcdefghi999\r\ntail Ybcdefghi555\r\n".utf8),
            to: "crlf.txt",
            in: dir
        )
    }
    let caseInsensitiveUnicodeFallbackFixture: (URL) throws -> Void = { dir in
        try write("alpha\nstraße\nCAFÉ\nİstanbul\n", to: "unicode", in: dir)
    }
    let wordUnicodeBoundaryFallbackFixture: (URL) throws -> Void = { dir in
        try write("émissingliteral\nmissingliteralé\nplain\n", to: "unicode-word", in: dir)
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
        ParityCase(name: "misc::case_insensitive_quiet_ascii_no_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["-i", "-q", "missingliteral", "ascii"]),
        ParityCase(name: "misc::case_insensitive_files_with_matches_ascii_no_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["-i", "-l", "missingliteral", "ascii"]),
        ParityCase(name: "misc::case_insensitive_files_without_match_ascii_no_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["-i", "-L", "missingliteral", "ascii"]),
        ParityCase(name: "misc::case_insensitive_unicode_fallback", fixture: caseInsensitiveUnicodeFallbackFixture, arguments: ["-i", "-q", "strasse", "unicode"]),
        ParityCase(name: "misc::json_ascii_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_ascii_ignore_case_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-i", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_word_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-w", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_ascii_ignore_case_word_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-i", "-w", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_context_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-C", "2", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_max_columns_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "--max-columns", "1", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_replacement_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-r", "x", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_line_regexp_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-x", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_only_matching_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-o", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_vimgrep_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "--vimgrep", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_crlf_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "--crlf", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_trim_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "--trim", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_stop_on_nonmatch_no_match_summary", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "--stop-on-nonmatch", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_files_with_matches_no_match_empty", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-l", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_files_with_matches_match_path", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-l", "Needle", "ascii"]),
        ParityCase(name: "misc::json_files_with_matches_ignore_case_word_match_path", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-i", "-w", "-l", "NEEDLE", "ascii"]),
        ParityCase(name: "misc::json_files_with_matches_exact_line_mismatch_empty", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-x", "-l", "Needle", "ascii"]),
        ParityCase(name: "misc::json_files_without_match_no_match_path", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "--files-without-match", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_files_without_match_match_empty", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "--files-without-match", "Needle", "ascii"]),
        ParityCase(name: "misc::json_count_no_match_empty", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-c", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_count_matches_no_match_empty", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "--count-matches", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_count_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-c", "Needle", "ascii"]),
        ParityCase(name: "misc::json_count_matches_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "--count-matches", "Needle", "ascii"]),
        ParityCase(name: "misc::json_count_ignore_case_word_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-i", "-w", "-c", "NEEDLE", "ascii"]),
        ParityCase(name: "misc::json_count_matches_ignore_case_word_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-i", "-w", "--count-matches", "NEEDLE", "ascii"]),
        ParityCase(name: "misc::json_count_include_zero_no_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "-c", "--include-zero", "missingliteral", "ascii"]),
        ParityCase(name: "misc::json_count_matches_include_zero_no_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["--json", "--count-matches", "--include-zero", "missingliteral", "ascii"]),
        ParityCase(name: "misc::word", fixture: sherlockFixture, arguments: ["-w", "as", "sherlock"]),
        ParityCase(name: "misc::word_quiet_ascii_no_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["-w", "-q", "missingliteral", "ascii"]),
        ParityCase(name: "misc::word_files_with_matches_ascii_no_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["-w", "-l", "missingliteral", "ascii"]),
        ParityCase(name: "misc::word_files_without_match_ascii_no_match", fixture: caseInsensitiveASCIIProofFixture, arguments: ["-w", "-L", "missingliteral", "ascii"]),
        ParityCase(name: "misc::word_unicode_boundary_fallback", fixture: wordUnicodeBoundaryFallbackFixture, arguments: ["-w", "-q", "missingliteral", "unicode-word"]),
        ParityCase(name: "misc::word_period", fixture: { dir in try write("...", to: "haystack", in: dir) }, arguments: ["-ow", ".", "haystack"]),
        ParityCase(name: "misc::line", fixture: sherlockFixture, arguments: ["-x", "Watson|and exhibited clearly, with a label attached.", "sherlock"]),
        ParityCase(name: "misc::line_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::line_number_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["-n", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::json_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["--json", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::json_only_matching_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["--json", "-o", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::color_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["--color=always", "[A-Z][a-z]{8}[0-9]{3}", "match.txt"]),
        ParityCase(name: "misc::only_matching_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["-o", "[A-Z][a-z]{8}[0-9]{3}", "match.txt"]),
        ParityCase(name: "misc::line_number_only_matching_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["-n", "-o", "[A-Z][a-z]{8}[0-9]{3}", "match.txt"]),
        ParityCase(name: "misc::byte_offset_only_matching_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["-b", "-o", "[A-Z][a-z]{8}[0-9]{3}", "match.txt"]),
        ParityCase(name: "misc::column_only_matching_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["--column", "-o", "[A-Z][a-z]{8}[0-9]{3}", "match.txt"]),
        ParityCase(name: "misc::vimgrep_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["--vimgrep", "[A-Z][a-z]{8}[0-9]{3}", "match.txt"]),
        ParityCase(name: "misc::files_with_matches_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["-l", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::files_without_match_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["--files-without-match", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::stats_files_with_matches_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["--stats", "-l", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::stats_files_without_match_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["--stats", "--files-without-match", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::quiet_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["-q", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::quiet_ascii_fixed_class_no_match", fixture: asciiFixedClassFixture, arguments: ["-q", "[A-Z][a-z]{8}[0-9]{3}", "miss.txt"]),
        ParityCase(name: "misc::count_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["-c", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::count_matches_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["--count-matches", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::stats_count_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["--stats", "-c", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::stats_count_matches_ascii_fixed_class", fixture: asciiFixedClassFixture, arguments: ["--stats", "--count-matches", "[A-Z][a-z]{8}[0-9]{3}", "."]),
        ParityCase(name: "misc::max_count_ascii_fixed_class", fixture: asciiFixedClassMaxCountFixture, arguments: ["-m1", "[A-Z][a-z]{8}[0-9]{3}", "max.txt"]),
        ParityCase(name: "misc::max_count_only_matching_ascii_fixed_class", fixture: asciiFixedClassMaxCountFixture, arguments: ["-o", "-m1", "[A-Z][a-z]{8}[0-9]{3}", "max.txt"]),
        ParityCase(name: "misc::stats_max_count_ascii_fixed_class", fixture: asciiFixedClassMaxCountFixture, arguments: ["--stats", "-m1", "[A-Z][a-z]{8}[0-9]{3}", "max.txt"]),
        ParityCase(name: "misc::json_max_count_ascii_fixed_class", fixture: asciiFixedClassMaxCountFixture, arguments: ["--json", "-m1", "[A-Z][a-z]{8}[0-9]{3}", "max.txt"]),
        ParityCase(name: "misc::crlf_ascii_fixed_class", fixture: asciiFixedClassCRLFFixture, arguments: ["--crlf", "[A-Z][a-z]{8}[0-9]{3}", "crlf.txt"]),
        ParityCase(name: "misc::crlf_only_matching_ascii_fixed_class", fixture: asciiFixedClassCRLFFixture, arguments: ["--crlf", "-o", "[A-Z][a-z]{8}[0-9]{3}", "crlf.txt"]),
        ParityCase(name: "misc::crlf_count_ascii_fixed_class", fixture: asciiFixedClassCRLFFixture, arguments: ["--crlf", "-c", "[A-Z][a-z]{8}[0-9]{3}", "crlf.txt"]),
        ParityCase(name: "misc::crlf_max_count_ascii_fixed_class", fixture: asciiFixedClassCRLFFixture, arguments: ["--crlf", "-m1", "[A-Z][a-z]{8}[0-9]{3}", "crlf.txt"]),
        ParityCase(name: "misc::json_crlf_ascii_fixed_class", fixture: asciiFixedClassCRLFFixture, arguments: ["--json", "--crlf", "[A-Z][a-z]{8}[0-9]{3}", "crlf.txt"]),
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

// MARK: - Timing normalization
//
// Rust `rg` emits real elapsed timings in JSON output (`elapsed` and
// `elapsed_total` fields). Swift `ripgrep` keeps those fields at zero for
// deterministic test output. To allow byte-comparing the rest of the JSON
// payload, both outputs are normalized through `normalize(_:for:)` which
// strips the inner key/value pairs of any `elapsed` / `elapsed_total`
// object before comparison. Text `--stats` output gets the same treatment for
// the two human-readable timing lines.

private func normalize(_ data: Data, for parityCase: ParityCase) -> Data {
    guard var text = String(data: data, encoding: .utf8) else { return data }
    if parityCase.arguments.contains("--json") {
        text = stripJSONTimingFields(in: text)
    }
    if parityCase.arguments.contains("--stats") {
        text = stripTextStatsTimingLines(in: text)
    }
    return Data(text.utf8)
}

private func stripTextStatsTimingLines(in text: String) -> String {
    text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            if line.hasSuffix(" seconds spent searching") {
                return "<elapsed> seconds spent searching"
            }
            if line.hasSuffix(" seconds total") {
                return "<elapsed> seconds total"
            }
            return String(line)
        }
        .joined(separator: "\n")
}

private func stripJSONTimingFields(in text: String) -> String {
    // The Rust and Swift writers happen to emit `elapsed` field children in
    // the same order, but the values inside differ (Rust real, Swift zero).
    // Strip the body of every `"elapsed":{...}` and `"elapsed_total":{...}`
    // object so the surrounding JSON can be byte-compared.
    var output = String()
    output.reserveCapacity(text.count)
    let keys = ["\"elapsed\":", "\"elapsed_total\":"]
    var index = text.startIndex
    while index < text.endIndex {
        var matchedKey: String? = nil
        for key in keys where text[index...].hasPrefix(key) {
            matchedKey = key
            break
        }
        guard let key = matchedKey else {
            output.append(text[index])
            index = text.index(after: index)
            continue
        }
        output.append(key)
        index = text.index(index, offsetBy: key.count)
        // Expect an opening brace immediately after the key.
        guard index < text.endIndex, text[index] == "{" else {
            continue
        }
        output.append("{}")
        // Walk past the timing object, respecting nested braces and strings.
        var depth = 0
        var inString = false
        var escape = false
        while index < text.endIndex {
            let ch = text[index]
            index = text.index(after: index)
            if escape {
                escape = false
                continue
            }
            if inString {
                if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            switch ch {
            case "\"":
                inString = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    break
                }
            default:
                break
            }
            if depth == 0 {
                break
            }
        }
    }
    return output
}

private let jsonElapsedDivergence: String? = nil

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

private func createDirectory(_ relativePath: String, in dir: URL) throws {
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(relativePath, isDirectory: true),
        withIntermediateDirectories: true
    )
}

private func write(_ data: Data, to relativePath: String, in dir: URL) throws {
    let fileURL = dir.appendingPathComponent(relativePath, isDirectory: false)
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
}

private func findRustRipgrep(packageRoot: URL) throws -> URL {
    if let configuredPath = ProcessInfo.processInfo.environment["SWIFT_RIPGREP_RUST_BINARY"],
       !configuredPath.isEmpty
    {
        let configuredURL = URL(fileURLWithPath: configuredPath)
        guard FileManager.default.isExecutableFile(atPath: configuredURL.path) else {
            XCTFail("SWIFT_RIPGREP_RUST_BINARY is not executable: \(configuredPath)")
            throw ParityHarnessError.missingRustRipgrep
        }
        return configuredURL
    }

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
        throw XCTSkip("Could not find Rust rg. Set SWIFT_RIPGREP_RUST_BINARY or put rg on PATH.")
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
    --- rust rg
    \(render(expected))
    """)
}

private func renderComparison(swift: ProcessResult, rust: ProcessResult) -> String {
    """
    --- swift-ripgrep
    \(render(swift))
    --- rust rg
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
    case missingRustRipgrep
}
