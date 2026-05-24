import Foundation

public enum TypeChange: Equatable, Sendable {
    case select(String)
    case negate(String)
    case clear(String)
    case add(String)
}

public struct FileTypeDefinition: Equatable, Sendable {
    public let name: String
    public let aliases: [String]
    public let globs: [String]

    public init(name: String, aliases: [String], globs: [String]) {
        self.name = name
        self.aliases = aliases
        self.globs = globs
    }
}

public struct FileTypeRegistry: Equatable, Sendable {
    private var definitionsByName: [String: FileTypeDefinition]
    private var aliasToName: [String: String]
    private var selected: Set<String> = []
    private var negated: Set<String> = []

    public init(loadDefaults: Bool = true) {
        self.definitionsByName = [:]
        self.aliasToName = [:]
        if loadDefaults {
            for definition in Self.defaultDefinitions {
                insert(definition)
            }
        }
    }

    public var definitions: [FileTypeDefinition] {
        definitionsByName.values.sorted { $0.name < $1.name }
    }

    @discardableResult
    public mutating func apply(_ changes: [TypeChange]) -> [String] {
        var errors: [String] = []
        var filters: [TypeChange] = []
        for change in changes {
            switch change {
            case .select, .negate:
                filters.append(change)
            case .clear(let name): clear(name)
            case .add(let spec):
                if !add(spec) {
                    errors.append("invalid definition (format is type:glob, e.g., html:*.html)")
                }
            }
        }
        for filter in filters {
            switch filter {
            case .select(let name):
                if !select(name) {
                    errors.append("unrecognized file type: \(name)")
                }
            case .negate(let name):
                if !negate(name) {
                    errors.append("unrecognized file type: \(name)")
                }
            case .clear, .add:
                break
            }
        }
        return errors
    }

    public func allows(path: String) -> Bool {
        guard !selected.isEmpty || !negated.isEmpty else { return true }
        let matched = matchingTypeNames(path: path)
        if !selected.isEmpty && selected.isDisjoint(with: matched) { return false }
        if !negated.isDisjoint(with: matched) { return false }
        return true
    }

    public func selectedTypeAllows(path: String) -> Bool {
        guard !selected.isEmpty else {
            return false
        }
        return allows(path: path)
    }

    public func typeListLines() -> [String] {
        definitions.map { "\($0.name): \($0.globs.sorted().joined(separator: ", "))" }
    }

    private mutating func select(_ rawName: String) -> Bool {
        if rawName == "all" {
            selected = Set(definitionsByName.keys)
            negated.removeAll()
            return true
        }
        guard let name = resolvedName(rawName) else {
            return false
        }
        selected.insert(name)
        negated.remove(name)
        return true
    }

    private mutating func negate(_ rawName: String) -> Bool {
        if rawName == "all" {
            negated = Set(definitionsByName.keys)
            return true
        }
        guard let name = resolvedName(rawName) else {
            return false
        }
        negated.insert(name)
        return true
    }

    private mutating func clear(_ rawName: String) {
        guard let name = resolvedName(rawName) ?? validName(rawName) else { return }
        let aliases = aliasToName.compactMap { alias, canonical in
            canonical == name ? alias : nil
        }
        for alias in aliases {
            definitionsByName.removeValue(forKey: alias)
            aliasToName.removeValue(forKey: alias)
        }
        definitionsByName.removeValue(forKey: name)
        aliasToName.removeValue(forKey: name)
        selected.remove(name)
        negated.remove(name)
    }

    private mutating func add(_ spec: String) -> Bool {
        let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let name = validName(parts[0]) else { return false }
        if parts.count == 3, parts[1] == "include" {
            let included = parts[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !included.isEmpty else { return false }
            for includedName in included {
                guard let canonical = resolvedName(includedName), let definition = definitionsByName[canonical] else {
                    return false
                }
                for glob in definition.globs { appendGlob(glob, to: name) }
            }
        } else {
            let glob = parts.dropFirst().joined(separator: ":")
            guard !glob.isEmpty else { return false }
            appendGlob(glob, to: name)
        }
        return true
    }

    private mutating func appendGlob(_ glob: String, to name: String) {
        if let existing = definitionsByName[name] {
            definitionsByName[name] = FileTypeDefinition(name: existing.name, aliases: existing.aliases, globs: existing.globs + [glob])
        } else {
            insert(FileTypeDefinition(name: name, aliases: [name], globs: [glob]))
        }
    }

    private mutating func insert(_ definition: FileTypeDefinition) {
        for alias in definition.aliases {
            definitionsByName[alias] = FileTypeDefinition(
                name: alias,
                aliases: [alias],
                globs: definition.globs
            )
        }
        for alias in definition.aliases { aliasToName[alias] = definition.name }
    }

    private func canonicalName(_ rawName: String) -> String? {
        aliasToName[rawName]
    }

    private func resolvedName(_ rawName: String) -> String? {
        guard let name = canonicalName(rawName),
              definitionsByName[name] != nil else {
            return nil
        }
        return name
    }

    private func validName(_ rawName: String) -> String? {
        !rawName.isEmpty && rawName.allSatisfy { $0.isLetter || $0.isNumber } ? rawName : nil
    }

    private func matchingTypeNames(path: String) -> Set<String> {
        Set(definitions.compactMap { definition in
            let matcher = GlobMatcher(patterns: definition.globs)
            return matcher.decision(relativePath: path, isDirectory: false) != nil ? definition.name : nil
        })
    }

    public static let defaultDefinitions: [FileTypeDefinition] = [
        FileTypeDefinition(name: "ada", aliases: ["ada"], globs: ["*.adb", "*.ads"]),
        FileTypeDefinition(name: "agda", aliases: ["agda"], globs: ["*.agda", "*.lagda"]),
        FileTypeDefinition(name: "aidl", aliases: ["aidl"], globs: ["*.aidl"]),
        FileTypeDefinition(name: "alire", aliases: ["alire"], globs: ["alire.toml"]),
        FileTypeDefinition(name: "amake", aliases: ["amake"], globs: ["*.mk", "*.bp"]),
        FileTypeDefinition(name: "asciidoc", aliases: ["asciidoc"], globs: ["*.adoc", "*.asc", "*.asciidoc"]),
        FileTypeDefinition(name: "asm", aliases: ["asm"], globs: ["*.asm", "*.s", "*.S"]),
        FileTypeDefinition(name: "asp", aliases: ["asp"], globs: ["*.aspx", "*.aspx.cs", "*.aspx.vb", "*.ascx", "*.ascx.cs", "*.ascx.vb", "*.asp"]),
        FileTypeDefinition(name: "ats", aliases: ["ats"], globs: ["*.ats", "*.dats", "*.sats", "*.hats"]),
        FileTypeDefinition(name: "avro", aliases: ["avro"], globs: ["*.avdl", "*.avpr", "*.avsc"]),
        FileTypeDefinition(name: "awk", aliases: ["awk"], globs: ["*.awk"]),
        FileTypeDefinition(name: "bat", aliases: ["bat", "batch"], globs: ["*.bat"]),
        FileTypeDefinition(name: "bazel", aliases: ["bazel"], globs: ["*.bazel", "*.bzl", "*.BUILD", "*.bazelrc", "BUILD", "MODULE.bazel", "WORKSPACE", "WORKSPACE.bazel", "WORKSPACE.bzlmod"]),
        FileTypeDefinition(name: "bitbake", aliases: ["bitbake"], globs: ["*.bb", "*.bbappend", "*.bbclass", "*.conf", "*.inc"]),
        FileTypeDefinition(name: "boxlang", aliases: ["boxlang"], globs: ["*.bx", "*.bxm", "*.bxs"]),
        FileTypeDefinition(name: "brotli", aliases: ["brotli"], globs: ["*.br"]),
        FileTypeDefinition(name: "buildstream", aliases: ["buildstream"], globs: ["*.bst"]),
        FileTypeDefinition(name: "bzip2", aliases: ["bzip2"], globs: ["*.bz2", "*.tbz2"]),
        FileTypeDefinition(name: "c", aliases: ["c"], globs: ["*.[chH]", "*.[chH].in", "*.cats"]),
        FileTypeDefinition(name: "cabal", aliases: ["cabal"], globs: ["*.cabal"]),
        FileTypeDefinition(name: "candid", aliases: ["candid"], globs: ["*.did"]),
        FileTypeDefinition(name: "carp", aliases: ["carp"], globs: ["*.carp"]),
        FileTypeDefinition(name: "cbor", aliases: ["cbor"], globs: ["*.cbor"]),
        FileTypeDefinition(name: "ceylon", aliases: ["ceylon"], globs: ["*.ceylon"]),
        FileTypeDefinition(name: "cfml", aliases: ["cfml"], globs: ["*.cfc", "*.cfm"]),
        FileTypeDefinition(name: "clojure", aliases: ["clojure"], globs: ["*.clj", "*.cljc", "*.cljs", "*.cljx"]),
        FileTypeDefinition(name: "cmake", aliases: ["cmake"], globs: ["*.cmake", "CMakeLists.txt"]),
        FileTypeDefinition(name: "cmd", aliases: ["cmd"], globs: ["*.bat", "*.cmd"]),
        FileTypeDefinition(name: "cml", aliases: ["cml"], globs: ["*.cml"]),
        FileTypeDefinition(name: "coffeescript", aliases: ["coffeescript"], globs: ["*.coffee"]),
        FileTypeDefinition(name: "config", aliases: ["config"], globs: ["*.cfg", "*.conf", "*.config", "*.ini"]),
        FileTypeDefinition(name: "container", aliases: ["container"], globs: ["*Containerfile*", "*Dockerfile*"]),
        FileTypeDefinition(name: "coq", aliases: ["coq"], globs: ["*.v"]),
        FileTypeDefinition(name: "cpp", aliases: ["cpp"], globs: ["*.[ChH]", "*.cc", "*.[ch]pp", "*.[ch]xx", "*.hh", "*.inl", "*.[ChH].in", "*.cc.in", "*.[ch]pp.in", "*.[ch]xx.in", "*.hh.in"]),
        FileTypeDefinition(name: "creole", aliases: ["creole"], globs: ["*.creole"]),
        FileTypeDefinition(name: "crystal", aliases: ["crystal"], globs: ["Projectfile", "*.cr", "*.ecr", "shard.yml"]),
        FileTypeDefinition(name: "cs", aliases: ["cs"], globs: ["*.cs"]),
        FileTypeDefinition(name: "csharp", aliases: ["csharp"], globs: ["*.cs"]),
        FileTypeDefinition(name: "cshtml", aliases: ["cshtml"], globs: ["*.cshtml"]),
        FileTypeDefinition(name: "csproj", aliases: ["csproj"], globs: ["*.csproj"]),
        FileTypeDefinition(name: "css", aliases: ["css"], globs: ["*.css", "*.scss"]),
        FileTypeDefinition(name: "csv", aliases: ["csv"], globs: ["*.csv"]),
        FileTypeDefinition(name: "cuda", aliases: ["cuda"], globs: ["*.cu", "*.cuh"]),
        FileTypeDefinition(name: "cython", aliases: ["cython"], globs: ["*.pyx", "*.pxi", "*.pxd"]),
        FileTypeDefinition(name: "d", aliases: ["d"], globs: ["*.d"]),
        FileTypeDefinition(name: "dart", aliases: ["dart"], globs: ["*.dart"]),
        FileTypeDefinition(name: "devicetree", aliases: ["devicetree"], globs: ["*.dts", "*.dtsi", "*.dtso"]),
        FileTypeDefinition(name: "dhall", aliases: ["dhall"], globs: ["*.dhall"]),
        FileTypeDefinition(name: "diff", aliases: ["diff"], globs: ["*.patch", "*.diff"]),
        FileTypeDefinition(name: "dita", aliases: ["dita"], globs: ["*.dita", "*.ditamap", "*.ditaval"]),
        FileTypeDefinition(name: "docker", aliases: ["docker"], globs: ["*Dockerfile*"]),
        FileTypeDefinition(name: "dockercompose", aliases: ["dockercompose"], globs: ["docker-compose.yml", "docker-compose.*.yml"]),
        FileTypeDefinition(name: "dts", aliases: ["dts"], globs: ["*.dts", "*.dtsi"]),
        FileTypeDefinition(name: "dvc", aliases: ["dvc"], globs: ["Dvcfile", "*.dvc"]),
        FileTypeDefinition(name: "ebuild", aliases: ["ebuild"], globs: ["*.ebuild", "*.eclass"]),
        FileTypeDefinition(name: "edn", aliases: ["edn"], globs: ["*.edn"]),
        FileTypeDefinition(name: "elisp", aliases: ["elisp"], globs: ["*.el"]),
        FileTypeDefinition(name: "elixir", aliases: ["elixir"], globs: ["*.ex", "*.eex", "*.exs", "*.heex", "*.leex", "*.livemd"]),
        FileTypeDefinition(name: "elm", aliases: ["elm"], globs: ["*.elm"]),
        FileTypeDefinition(name: "erb", aliases: ["erb"], globs: ["*.erb"]),
        FileTypeDefinition(name: "erlang", aliases: ["erlang"], globs: ["*.erl", "*.hrl"]),
        FileTypeDefinition(name: "fennel", aliases: ["fennel"], globs: ["*.fnl"]),
        FileTypeDefinition(name: "fidl", aliases: ["fidl"], globs: ["*.fidl"]),
        FileTypeDefinition(name: "fish", aliases: ["fish"], globs: ["*.fish"]),
        FileTypeDefinition(name: "flatbuffers", aliases: ["flatbuffers"], globs: ["*.fbs"]),
        FileTypeDefinition(name: "fortran", aliases: ["fortran"], globs: ["*.f", "*.F", "*.f77", "*.F77", "*.pfo", "*.f90", "*.F90", "*.f95", "*.F95"]),
        FileTypeDefinition(name: "fsharp", aliases: ["fsharp"], globs: ["*.fs", "*.fsx", "*.fsi"]),
        FileTypeDefinition(name: "fut", aliases: ["fut"], globs: ["*.fut"]),
        FileTypeDefinition(name: "gap", aliases: ["gap"], globs: ["*.g", "*.gap", "*.gi", "*.gd", "*.tst"]),
        FileTypeDefinition(name: "gdscript", aliases: ["gdscript"], globs: ["*.gd"]),
        FileTypeDefinition(name: "gleam", aliases: ["gleam"], globs: ["*.gleam"]),
        FileTypeDefinition(name: "gn", aliases: ["gn"], globs: ["*.gn", "*.gni"]),
        FileTypeDefinition(name: "go", aliases: ["go"], globs: ["*.go"]),
        FileTypeDefinition(name: "gprbuild", aliases: ["gprbuild"], globs: ["*.gpr"]),
        FileTypeDefinition(name: "gradle", aliases: ["gradle"], globs: ["*.gradle", "*.gradle.kts", "gradle.properties", "gradle-wrapper.*", "gradlew", "gradlew.bat"]),
        FileTypeDefinition(name: "graphql", aliases: ["graphql"], globs: ["*.graphql", "*.graphqls"]),
        FileTypeDefinition(name: "groovy", aliases: ["groovy"], globs: ["*.groovy", "*.gradle"]),
        FileTypeDefinition(name: "gzip", aliases: ["gzip"], globs: ["*.gz", "*.tgz"]),
        FileTypeDefinition(name: "h", aliases: ["h"], globs: ["*.h", "*.hh", "*.hpp"]),
        FileTypeDefinition(name: "haml", aliases: ["haml"], globs: ["*.haml"]),
        FileTypeDefinition(name: "hare", aliases: ["hare"], globs: ["*.ha"]),
        FileTypeDefinition(name: "haskell", aliases: ["haskell"], globs: ["*.hs", "*.lhs", "*.cpphs", "*.c2hs", "*.hsc"]),
        FileTypeDefinition(name: "hbs", aliases: ["hbs"], globs: ["*.hbs"]),
        FileTypeDefinition(name: "hs", aliases: ["hs"], globs: ["*.hs", "*.lhs"]),
        FileTypeDefinition(name: "html", aliases: ["html"], globs: ["*.htm", "*.html", "*.ejs"]),
        FileTypeDefinition(name: "hy", aliases: ["hy"], globs: ["*.hy"]),
        FileTypeDefinition(name: "idris", aliases: ["idris"], globs: ["*.idr", "*.lidr"]),
        FileTypeDefinition(name: "janet", aliases: ["janet"], globs: ["*.janet"]),
        FileTypeDefinition(name: "java", aliases: ["java"], globs: ["*.java", "*.jsp", "*.jspx", "*.properties"]),
        FileTypeDefinition(name: "jinja", aliases: ["jinja"], globs: ["*.j2", "*.jinja", "*.jinja2"]),
        FileTypeDefinition(name: "jl", aliases: ["jl"], globs: ["*.jl"]),
        FileTypeDefinition(name: "js", aliases: ["js"], globs: ["*.js", "*.jsx", "*.vue", "*.cjs", "*.mjs"]),
        FileTypeDefinition(name: "json", aliases: ["json"], globs: ["*.json", "composer.lock", "*.sarif"]),
        FileTypeDefinition(name: "jsonl", aliases: ["jsonl"], globs: ["*.jsonl"]),
        FileTypeDefinition(name: "julia", aliases: ["julia"], globs: ["*.jl"]),
        FileTypeDefinition(name: "jupyter", aliases: ["jupyter"], globs: ["*.ipynb", "*.jpynb"]),
        FileTypeDefinition(name: "k", aliases: ["k"], globs: ["*.k"]),
        FileTypeDefinition(name: "kconfig", aliases: ["kconfig"], globs: ["Kconfig", "Kconfig.*"]),
        FileTypeDefinition(name: "kotlin", aliases: ["kotlin"], globs: ["*.kt", "*.kts"]),
        FileTypeDefinition(name: "lean", aliases: ["lean"], globs: ["*.lean"]),
        FileTypeDefinition(name: "less", aliases: ["less"], globs: ["*.less"]),
        FileTypeDefinition(name: "license", aliases: ["license"], globs: ["COPYING", "COPYING[.-]*", "COPYRIGHT", "COPYRIGHT[.-]*", "EULA", "EULA[.-]*", "licen[cs]e", "licen[cs]e.*", "LICEN[CS]E", "LICEN[CS]E[.-]*", "*[.-]LICEN[CS]E*", "NOTICE", "NOTICE[.-]*", "PATENTS", "PATENTS[.-]*", "UNLICEN[CS]E", "UNLICEN[CS]E[.-]*", "agpl[.-]*", "gpl[.-]*", "lgpl[.-]*", "AGPL-*[0-9]*", "APACHE-*[0-9]*", "BSD-*[0-9]*", "CC-BY-*", "GFDL-*[0-9]*", "GNU-*[0-9]*", "GPL-*[0-9]*", "LGPL-*[0-9]*", "MIT-*[0-9]*", "MPL-*[0-9]*", "OFL-*[0-9]*"]),
        FileTypeDefinition(name: "lilypond", aliases: ["lilypond"], globs: ["*.ly", "*.ily"]),
        FileTypeDefinition(name: "lisp", aliases: ["lisp"], globs: ["*.el", "*.jl", "*.lisp", "*.lsp", "*.sc", "*.scm"]),
        FileTypeDefinition(name: "llvm", aliases: ["llvm"], globs: ["*.ll"]),
        FileTypeDefinition(name: "lock", aliases: ["lock"], globs: ["*.lock", "package-lock.json"]),
        FileTypeDefinition(name: "log", aliases: ["log"], globs: ["*.log"]),
        FileTypeDefinition(name: "lua", aliases: ["lua"], globs: ["*.lua"]),
        FileTypeDefinition(name: "lz4", aliases: ["lz4"], globs: ["*.lz4"]),
        FileTypeDefinition(name: "lzma", aliases: ["lzma"], globs: ["*.lzma"]),
        FileTypeDefinition(name: "m4", aliases: ["m4"], globs: ["*.ac", "*.m4"]),
        FileTypeDefinition(name: "make", aliases: ["make"], globs: ["[Gg][Nn][Uu]makefile", "[Mm]akefile", "[Gg][Nn][Uu]makefile.am", "[Mm]akefile.am", "[Gg][Nn][Uu]makefile.in", "[Mm]akefile.in", "Makefile.*", "*.mk", "*.mak"]),
        FileTypeDefinition(name: "mako", aliases: ["mako"], globs: ["*.mako", "*.mao"]),
        FileTypeDefinition(name: "man", aliases: ["man"], globs: ["*.[0-9lnpx]", "*.[0-9][cEFMmpSx]"]),
        FileTypeDefinition(name: "markdown", aliases: ["markdown", "md"], globs: ["*.markdown", "*.md", "*.mdown", "*.mdwn", "*.mkd", "*.mkdn", "*.mdx"]),
        FileTypeDefinition(name: "matlab", aliases: ["matlab"], globs: ["*.m"]),
        FileTypeDefinition(name: "meson", aliases: ["meson"], globs: ["meson.build", "meson_options.txt", "meson.options"]),
        FileTypeDefinition(name: "minified", aliases: ["minified"], globs: ["*.min.html", "*.min.css", "*.min.js"]),
        FileTypeDefinition(name: "mint", aliases: ["mint"], globs: ["*.mint"]),
        FileTypeDefinition(name: "mk", aliases: ["mk"], globs: ["mkfile"]),
        FileTypeDefinition(name: "ml", aliases: ["ml"], globs: ["*.ml"]),
        FileTypeDefinition(name: "motoko", aliases: ["motoko"], globs: ["*.mo"]),
        FileTypeDefinition(name: "msbuild", aliases: ["msbuild"], globs: ["*.csproj", "*.fsproj", "*.vcxproj", "*.proj", "*.props", "*.targets", "*.sln", "*.slnf"]),
        FileTypeDefinition(name: "nim", aliases: ["nim"], globs: ["*.nim", "*.nimf", "*.nimble", "*.nims"]),
        FileTypeDefinition(name: "nix", aliases: ["nix"], globs: ["*.nix"]),
        FileTypeDefinition(name: "objc", aliases: ["objc"], globs: ["*.h", "*.m"]),
        FileTypeDefinition(name: "objcpp", aliases: ["objcpp"], globs: ["*.h", "*.mm"]),
        FileTypeDefinition(name: "ocaml", aliases: ["ocaml"], globs: ["*.ml", "*.mli", "*.mll", "*.mly"]),
        FileTypeDefinition(name: "org", aliases: ["org"], globs: ["*.org", "*.org_archive"]),
        FileTypeDefinition(name: "pants", aliases: ["pants"], globs: ["BUILD"]),
        FileTypeDefinition(name: "pascal", aliases: ["pascal"], globs: ["*.pas", "*.dpr", "*.lpr", "*.pp", "*.inc"]),
        FileTypeDefinition(name: "pdf", aliases: ["pdf"], globs: ["*.pdf"]),
        FileTypeDefinition(name: "perl", aliases: ["perl"], globs: ["*.perl", "*.pl", "*.PL", "*.plh", "*.plx", "*.pm", "*.t"]),
        FileTypeDefinition(name: "php", aliases: ["php"], globs: ["*.php", "*.php3", "*.php4", "*.php5", "*.php7", "*.php8", "*.pht", "*.phtml"]),
        FileTypeDefinition(name: "po", aliases: ["po"], globs: ["*.po"]),
        FileTypeDefinition(name: "pod", aliases: ["pod"], globs: ["*.pod"]),
        FileTypeDefinition(name: "postscript", aliases: ["postscript"], globs: ["*.eps", "*.ps"]),
        FileTypeDefinition(name: "prolog", aliases: ["prolog"], globs: ["*.pl", "*.pro", "*.prolog", "*.P"]),
        FileTypeDefinition(name: "protobuf", aliases: ["protobuf"], globs: ["*.proto"]),
        FileTypeDefinition(name: "ps", aliases: ["ps"], globs: ["*.cdxml", "*.ps1", "*.ps1xml", "*.psd1", "*.psm1"]),
        FileTypeDefinition(name: "puppet", aliases: ["puppet"], globs: ["*.epp", "*.erb", "*.pp", "*.rb"]),
        FileTypeDefinition(name: "purs", aliases: ["purs"], globs: ["*.purs"]),
        FileTypeDefinition(name: "py", aliases: ["py", "python"], globs: ["*.py", "*.pyi"]),
        FileTypeDefinition(name: "qmake", aliases: ["qmake"], globs: ["*.pro", "*.pri", "*.prf"]),
        FileTypeDefinition(name: "qml", aliases: ["qml"], globs: ["*.qml"]),
        FileTypeDefinition(name: "qrc", aliases: ["qrc"], globs: ["*.qrc"]),
        FileTypeDefinition(name: "qui", aliases: ["qui"], globs: ["*.ui"]),
        FileTypeDefinition(name: "r", aliases: ["r"], globs: ["*.R", "*.r", "*.Rmd", "*.rmd", "*.Rnw", "*.rnw"]),
        FileTypeDefinition(name: "racket", aliases: ["racket"], globs: ["*.rkt"]),
        FileTypeDefinition(name: "raku", aliases: ["raku"], globs: ["*.raku", "*.rakumod", "*.rakudoc", "*.rakutest", "*.p6", "*.pl6", "*.pm6"]),
        FileTypeDefinition(name: "rdoc", aliases: ["rdoc"], globs: ["*.rdoc"]),
        FileTypeDefinition(name: "readme", aliases: ["readme"], globs: ["README*", "*README"]),
        FileTypeDefinition(name: "reasonml", aliases: ["reasonml"], globs: ["*.re", "*.rei"]),
        FileTypeDefinition(name: "red", aliases: ["red"], globs: ["*.r", "*.red", "*.reds"]),
        FileTypeDefinition(name: "rescript", aliases: ["rescript"], globs: ["*.res", "*.resi"]),
        FileTypeDefinition(name: "robot", aliases: ["robot"], globs: ["*.robot"]),
        FileTypeDefinition(name: "rst", aliases: ["rst"], globs: ["*.rst"]),
        FileTypeDefinition(name: "ruby", aliases: ["ruby"], globs: ["config.ru", "Gemfile", ".irbrc", "Rakefile", "*.gemspec", "*.rb", "*.rbw", "*.rake"]),
        FileTypeDefinition(name: "rust", aliases: ["rust"], globs: ["*.rs"]),
        FileTypeDefinition(name: "sass", aliases: ["sass"], globs: ["*.sass", "*.scss"]),
        FileTypeDefinition(name: "scala", aliases: ["scala"], globs: ["*.scala", "*.sbt"]),
        FileTypeDefinition(name: "scdoc", aliases: ["scdoc"], globs: ["*.scd", "*.scdoc"]),
        FileTypeDefinition(name: "seed7", aliases: ["seed7"], globs: ["*.sd7", "*.s7i"]),
        FileTypeDefinition(name: "sh", aliases: ["sh"], globs: [".env", ".login", ".logout", ".profile", "profile", ".bash_login", "bash_login", ".bash_logout", "bash_logout", ".bash_profile", "bash_profile", ".bashrc", "bashrc", "*.bashrc", ".cshrc", "*.cshrc", ".kshrc", "*.kshrc", ".tcshrc", ".zshenv", "zshenv", ".zlogin", "zlogin", ".zlogout", "zlogout", ".zprofile", "zprofile", ".zshrc", "zshrc", "*.bash", "*.csh", "*.env", "*.ksh", "*.sh", "*.tcsh", "*.zsh"]),
        FileTypeDefinition(name: "slim", aliases: ["slim"], globs: ["*.skim", "*.slim", "*.slime"]),
        FileTypeDefinition(name: "smarty", aliases: ["smarty"], globs: ["*.tpl"]),
        FileTypeDefinition(name: "sml", aliases: ["sml"], globs: ["*.sml", "*.sig"]),
        FileTypeDefinition(name: "solidity", aliases: ["solidity"], globs: ["*.sol"]),
        FileTypeDefinition(name: "soy", aliases: ["soy"], globs: ["*.soy"]),
        FileTypeDefinition(name: "spark", aliases: ["spark"], globs: ["*.spark"]),
        FileTypeDefinition(name: "spec", aliases: ["spec"], globs: ["*.spec"]),
        FileTypeDefinition(name: "sql", aliases: ["sql"], globs: ["*.sql", "*.psql"]),
        FileTypeDefinition(name: "ssa", aliases: ["ssa"], globs: ["*.ssa"]),
        FileTypeDefinition(name: "stylus", aliases: ["stylus"], globs: ["*.styl"]),
        FileTypeDefinition(name: "sv", aliases: ["sv"], globs: ["*.v", "*.vg", "*.sv", "*.svh", "*.h"]),
        FileTypeDefinition(name: "svelte", aliases: ["svelte"], globs: ["*.svelte", "*.svelte.ts"]),
        FileTypeDefinition(name: "svg", aliases: ["svg"], globs: ["*.svg"]),
        FileTypeDefinition(name: "swift", aliases: ["swift"], globs: ["*.swift"]),
        FileTypeDefinition(name: "swig", aliases: ["swig"], globs: ["*.def", "*.i"]),
        FileTypeDefinition(name: "systemd", aliases: ["systemd"], globs: ["*.automount", "*.conf", "*.device", "*.link", "*.mount", "*.path", "*.scope", "*.service", "*.slice", "*.socket", "*.swap", "*.target", "*.timer"]),
        FileTypeDefinition(name: "taskpaper", aliases: ["taskpaper"], globs: ["*.taskpaper"]),
        FileTypeDefinition(name: "tcl", aliases: ["tcl"], globs: ["*.tcl"]),
        FileTypeDefinition(name: "tex", aliases: ["tex"], globs: ["*.tex", "*.ltx", "*.cls", "*.sty", "*.bib", "*.dtx", "*.ins"]),
        FileTypeDefinition(name: "texinfo", aliases: ["texinfo"], globs: ["*.texi"]),
        FileTypeDefinition(name: "textile", aliases: ["textile"], globs: ["*.textile"]),
        FileTypeDefinition(name: "tf", aliases: ["tf"], globs: ["*.tf", "*.tf.json", "*.tfvars", "*.tfvars.json", "*.terraformrc", "terraform.rc", "*.tfrc", "*.terraform.lock.hcl"]),
        FileTypeDefinition(name: "thrift", aliases: ["thrift"], globs: ["*.thrift"]),
        FileTypeDefinition(name: "toml", aliases: ["toml"], globs: ["*.toml", "Cargo.lock"]),
        FileTypeDefinition(name: "ts", aliases: ["ts", "typescript"], globs: ["*.ts", "*.tsx", "*.cts", "*.mts"]),
        FileTypeDefinition(name: "twig", aliases: ["twig"], globs: ["*.twig"]),
        FileTypeDefinition(name: "txt", aliases: ["txt"], globs: ["*.txt"]),
        FileTypeDefinition(name: "typoscript", aliases: ["typoscript"], globs: ["*.typoscript", "*.ts"]),
        FileTypeDefinition(name: "typst", aliases: ["typst"], globs: ["*.typ"]),
        FileTypeDefinition(name: "usd", aliases: ["usd"], globs: ["*.usd", "*.usda", "*.usdc"]),
        FileTypeDefinition(name: "v", aliases: ["v"], globs: ["*.v", "*.vsh"]),
        FileTypeDefinition(name: "vala", aliases: ["vala"], globs: ["*.vala"]),
        FileTypeDefinition(name: "vb", aliases: ["vb"], globs: ["*.vb"]),
        FileTypeDefinition(name: "vcl", aliases: ["vcl"], globs: ["*.vcl"]),
        FileTypeDefinition(name: "verilog", aliases: ["verilog"], globs: ["*.v", "*.vh", "*.sv", "*.svh"]),
        FileTypeDefinition(name: "vhdl", aliases: ["vhdl"], globs: ["*.vhd", "*.vhdl"]),
        FileTypeDefinition(name: "vim", aliases: ["vim"], globs: ["*.vim", ".vimrc", ".gvimrc", "vimrc", "gvimrc", "_vimrc", "_gvimrc"]),
        FileTypeDefinition(name: "vimscript", aliases: ["vimscript"], globs: ["*.vim", ".vimrc", ".gvimrc", "vimrc", "gvimrc", "_vimrc", "_gvimrc"]),
        FileTypeDefinition(name: "vue", aliases: ["vue"], globs: ["*.vue"]),
        FileTypeDefinition(name: "webidl", aliases: ["webidl"], globs: ["*.idl", "*.webidl", "*.widl"]),
        FileTypeDefinition(name: "wgsl", aliases: ["wgsl"], globs: ["*.wgsl"]),
        FileTypeDefinition(name: "wiki", aliases: ["wiki"], globs: ["*.mediawiki", "*.wiki"]),
        FileTypeDefinition(name: "xml", aliases: ["xml"], globs: ["*.xml", "*.xml.dist", "*.dtd", "*.xsl", "*.xslt", "*.xsd", "*.xjb", "*.rng", "*.sch", "*.xhtml"]),
        FileTypeDefinition(name: "xz", aliases: ["xz"], globs: ["*.xz", "*.txz"]),
        FileTypeDefinition(name: "yacc", aliases: ["yacc"], globs: ["*.y"]),
        FileTypeDefinition(name: "yaml", aliases: ["yaml"], globs: ["*.yaml", "*.yml"]),
        FileTypeDefinition(name: "yang", aliases: ["yang"], globs: ["*.yang"]),
        FileTypeDefinition(name: "z", aliases: ["z"], globs: ["*.Z"]),
        FileTypeDefinition(name: "zig", aliases: ["zig"], globs: ["*.zig"]),
        FileTypeDefinition(name: "zsh", aliases: ["zsh"], globs: [".zshenv", "zshenv", ".zlogin", "zlogin", ".zlogout", "zlogout", ".zprofile", "zprofile", ".zshrc", "zshrc", "*.zsh"]),
        FileTypeDefinition(name: "zstd", aliases: ["zstd"], globs: ["*.zst", "*.zstd"]),
    ]
}
