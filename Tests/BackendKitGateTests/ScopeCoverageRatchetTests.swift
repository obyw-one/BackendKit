import CoreKitTestSupport
import Foundation
import Testing

// MARK: - DeclaredScope

/// A scope `.kagami/scopes.override.toml` declares, read just far enough to answer one question: which scope runs
/// which test file. `kagami test --all --strict` runs the DECLARED scopes, so a test file no scope selects is
/// never run and the gate stays green over it.
private struct DeclaredScope: Equatable {
    let name: String
    let testTarget: String?
    let filePatterns: [String]
    let typePatterns: [String]
}

// MARK: - ScopeRegistry

private enum ScopeRegistry {
    static func parse(_ text: String) -> [DeclaredScope] {
        text.components(separatedBy: "[[scopes]]").dropFirst().compactMap { block in
            guard let name = values(of: "name", in: block, isList: false).first else { return nil }
            return DeclaredScope(
                name: name,
                testTarget: values(of: "test_target_name", in: block, isList: false).first,
                filePatterns: values(of: "test_file_patterns", in: block, isList: true),
                typePatterns: values(of: "type_patterns", in: block, isList: true)
            )
        }
    }

    private static func values(of key: String, in block: String, isList: Bool) -> [String] {
        let pattern = isList ? "(?m)^\(key) = \\[([^\\]]*)\\]" : "(?m)^\(key) = \"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
            let range = Range(match.range(at: 1), in: block)
        else { return [] }
        let body = String(block[range])
        guard isList else { return [body] }
        guard let quoted = try? NSRegularExpression(pattern: "\"([^\"]*)\"") else { return [] }
        return quoted.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        }
    }
}

// MARK: - Census

private struct Census: Equatable {
    /// Test files no scope runs.
    var orphans: [String] = []
    /// Test files several scopes run (path to the scopes' names).
    var shared: [String: [String]] = [:]
    /// Suites inside a selected file that the owning scope's `type_patterns` never select.
    var suitesOutsideTheirScope: [String] = []
    /// Test directories `Package.swift` declares no `.testTarget` for: they are never even compiled.
    var uncompiledDirectories: [String] = []
}

private enum ScopeCoverage {
    /// The glob grammar's own separator (the patterns are written with it), not a path construction.
    private static let separator = "/"

    /// `**/` is any directory prefix (or none), `**` any characters, `*` any characters within one component.
    static func matches(_ pattern: String, _ path: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: separator)
        var out = "^"
        var rest = Substring(pattern)
        while let head = rest.first {
            if rest.hasPrefix("**" + separator) {
                out += "(?:.*\(escaped))?"
                rest = rest.dropFirst(3)
            } else if rest.hasPrefix("**") {
                out += ".*"
                rest = rest.dropFirst(2)
            } else if head == "*" {
                out += "[^\(escaped)]*"
                rest = rest.dropFirst()
            } else {
                out += NSRegularExpression.escapedPattern(for: String(head))
                rest = rest.dropFirst()
            }
        }
        return path.range(of: out + "$", options: .regularExpression) != nil
    }

    /// A scope with `test_file_patterns` owns what they match; one without owns its whole test target directory.
    static func owns(_ scope: DeclaredScope, _ path: String) -> Bool {
        if !scope.filePatterns.isEmpty { return scope.filePatterns.contains { matches($0, path) } }
        guard let target = scope.testTarget else { return false }
        return matches("Tests" + separator + target + separator + "**.swift", path)
    }

    /// `files` maps a package-relative path to the `*Tests` types it declares; `compiledTargets` are the
    /// `.testTarget` names of `Package.swift`.
    static func census(files: [String: [String]], scopes: [DeclaredScope], compiledTargets: Set<String>) -> Census {
        var census = Census()
        var directories = Set<String>()
        for (path, types) in files.sorted(by: { $0.key < $1.key }) {
            let parts = path.components(separatedBy: separator)
            if parts.count > 2 { directories.insert(parts[1]) }
            let owners = scopes.filter { owns($0, path) }
            if owners.isEmpty { census.orphans.append(path) }
            if owners.count > 1 { census.shared[path] = owners.map(\.name) }
            guard let owner = owners.first, !owner.typePatterns.isEmpty else { continue }
            for type in types where !owner.typePatterns.contains(where: { type.contains($0) }) {
                census.suitesOutsideTheirScope.append("\(path): \(type) is not in \(owner.name)'s type_patterns")
            }
        }
        census.uncompiledDirectories = directories.subtracting(compiledTargets).sorted()
        return census
    }
}

// MARK: - ScopeCoverageRatchetTests

@Suite("Scope coverage: every test file is run by exactly one declared scope, its suites are selected, its directory is compiled")
struct ScopeCoverageRatchetTests {
    private static func repositoryFiles() throws -> [String: [String]] {
        let root = TestPackagePaths.packageRoot()
        let tests = root.appending(path: "Tests", directoryHint: .isDirectory)
        guard let walker = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil) else { return [:] }
        let declaration = try NSRegularExpression(
            pattern: "(?m)^\\s*(?:private |fileprivate |public )?(?:final )?(?:struct|class|actor|enum) (\\w+Tests)\\b")
        let rootCount = root.standardizedFileURL.pathComponents.count
        var files: [String: [String]] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootCount).joined(separator: "/")
            let text = try String(contentsOf: url, encoding: .utf8)
            files[relative] = declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        return files
    }

    private static func declaredScopes() throws -> [DeclaredScope] {
        let registry = TestPackagePaths.packageRoot()
            .appending(path: ".kagami", directoryHint: .isDirectory)
            .appending(path: "scopes.override.toml", directoryHint: .notDirectory)
        return ScopeRegistry.parse(try String(contentsOf: registry, encoding: .utf8))
    }

    private static func compiledTestTargets() throws -> Set<String> {
        let manifest = try String(
            contentsOf: TestPackagePaths.packageRoot().appending(path: "Package.swift", directoryHint: .notDirectory),
            encoding: .utf8)
        let regex = try NSRegularExpression(pattern: "\\.testTarget\\(\\s*name: \"(\\w+)\"")
        return Set(
            regex.matches(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)).compactMap {
                Range($0.range(at: 1), in: manifest).map { String(manifest[$0]) }
            })
    }

    @Test("the real registry: no orphan test file, none owned twice, no suite outside its scope's filter, no uncompiled directory")
    func realRegistry() throws {
        let files = try Self.repositoryFiles()
        let scopes = try Self.declaredScopes()
        #expect(files.count >= 20, "the walker found too few test files: locator drift?")
        #expect(scopes.count >= 5, "the registry parse found too few scopes")
        let census = ScopeCoverage.census(files: files, scopes: scopes, compiledTargets: try Self.compiledTestTargets())
        #expect(census.orphans.isEmpty, "test files no scope runs: \(census.orphans)")
        #expect(census.shared.isEmpty, "test files owned by several scopes: \(census.shared)")
        #expect(census.suitesOutsideTheirScope.isEmpty, "suites their scope never selects: \(census.suitesOutsideTheirScope)")
        #expect(census.uncompiledDirectories.isEmpty, "test directories without a .testTarget: \(census.uncompiledDirectories)")
    }

    // MARK: The detector itself

    private let scopes = [
        DeclaredScope(name: "A", testTarget: nil, filePatterns: ["**/T/A/**.swift"], typePatterns: ["AlphaTests"]),
        DeclaredScope(name: "B", testTarget: nil, filePatterns: ["**/T/*.swift", "**/T/B/**.swift"], typePatterns: ["BetaTests"]),
        DeclaredScope(name: "ByTarget", testTarget: "Whole", filePatterns: [], typePatterns: []),
    ]
    private let compiled: Set<String> = ["T", "Whole"]

    @Test("a file no scope matches is an orphan")
    func detectsOrphan() {
        let census = ScopeCoverage.census(files: ["Tests/T/C/Lost.swift": ["LostTests"]], scopes: scopes, compiledTargets: compiled)
        #expect(census.orphans == ["Tests/T/C/Lost.swift"])
    }

    @Test("a file two scopes match is shared")
    func detectsDoubleOwner() {
        let both = [scopes[0], DeclaredScope(name: "Greedy", testTarget: nil, filePatterns: ["**/T/**.swift"], typePatterns: [])]
        let census = ScopeCoverage.census(files: ["Tests/T/A/X.swift": ["AlphaTests"]], scopes: both, compiledTargets: compiled)
        #expect(census.shared == ["Tests/T/A/X.swift": ["A", "Greedy"]])
    }

    @Test("a suite its owning scope's type_patterns do not select is reported")
    func detectsSilentSuite() {
        let census = ScopeCoverage.census(
            files: ["Tests/T/A/X.swift": ["AlphaTests", "ForgottenTests"]], scopes: scopes, compiledTargets: compiled)
        #expect(census.suitesOutsideTheirScope.count == 1)
        #expect(census.suitesOutsideTheirScope.first?.contains("ForgottenTests") == true)
    }

    @Test("a scope without file patterns owns its whole test target directory, and a scope without type patterns selects every suite")
    func targetOwnership() {
        let census = ScopeCoverage.census(
            files: ["Tests/Whole/Deep/Any.swift": ["AnythingTests"]], scopes: scopes, compiledTargets: compiled)
        #expect(census == Census())
    }

    @Test("a test directory Package.swift declares no testTarget for is reported as uncompiled")
    func detectsUncompiledDirectory() {
        let census = ScopeCoverage.census(
            files: ["Tests/Whole/A.swift": [], "Tests/Ghost/B.swift": []], scopes: scopes, compiledTargets: ["Whole"])
        #expect(census.uncompiledDirectories == ["Ghost"])
    }

    @Test("a covered tree is clean, and a single-star glob does not reach into subfolders")
    func cleanAndGlobSemantics() {
        let clean = ScopeCoverage.census(
            files: ["Tests/T/Top.swift": ["BetaTests"], "Tests/T/A/Deep.swift": ["AlphaTests"]], scopes: scopes, compiledTargets: compiled)
        #expect(clean == Census())
        #expect(ScopeCoverage.matches("**/T/*.swift", "Tests/T/Top.swift"))
        #expect(!ScopeCoverage.matches("**/T/*.swift", "Tests/T/Sub/Deep.swift"))
        #expect(ScopeCoverage.matches("**/T/**.swift", "Tests/T/Sub/Deep.swift"))
    }

    @Test("the registry parser reads names, test targets, file patterns and type patterns")
    func parser() {
        let parsed = ScopeRegistry.parse("""
            # c
            [[scopes]]
            name = "One"
            test_target_name = "OneTests"
            type_patterns = ["XTests", "YTests"]
            test_file_patterns = ["**/X/**.swift"]

            [[scopes]]
            name = "Two"
            type_patterns = ["ZTests"]
            test_file_patterns = ["**/Z/*.swift", "**/W/**.swift"]
            """)
        #expect(parsed == [
            DeclaredScope(name: "One", testTarget: "OneTests", filePatterns: ["**/X/**.swift"], typePatterns: ["XTests", "YTests"]),
            DeclaredScope(name: "Two", testTarget: nil, filePatterns: ["**/Z/*.swift", "**/W/**.swift"], typePatterns: ["ZTests"]),
        ])
    }
}
