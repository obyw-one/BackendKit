import CoreKitTestSupport
import Foundation
import Testing

// MARK: - ManifestShapeTests

//
// The driver-leak silent-fail (spec b7e2d4f6 §Silent-fail): `BackendKitCore`
// must NOT depend on any Postgres/libSQL/DuckDB driver — a consumer that
// wants driver-free primitives (an SPM plugin, a lint-only test target)
// otherwise pays for the transitive weight. The manifest itself is the SSoT:
// grep-assert its contents rather than build a target graph.
//
// Package location goes through CoreKit's `TestPackagePaths` (the fleet SSoT,
// BackendKit #2 review) — never a hand-counted `#filePath` walk.

@Suite("Package.swift shape — BackendKitCore stays driver-free")
struct ManifestShapeTests {
    // MARK: - Package.swift locator

    private static func readManifest() throws -> String {
        try String(
            contentsOf: TestPackagePaths.packageRoot().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
    }

    // MARK: - Assertions

    @Test("BackendKitCore has no driver dependency")
    func coreHasNoDriverDependency() throws {
        let manifest = try Self.readManifest()

        guard let coreTargetRange = Self.range(ofTargetNamed: "BackendKitCore", in: manifest) else {
            Issue.record("BackendKitCore target block not found in Package.swift")
            return
        }
        let coreBlock = String(manifest[coreTargetRange])

        // The engine drivers: none of them may appear inside BackendKitCore's
        // target block (a consumer of Core alone pays no driver weight).
        let forbidden = ["PostgresNIO", "postgres-nio", "Libsql", "libsql", "DuckDB", "duckdb"]
        for needle in forbidden {
            #expect(
                !coreBlock.contains(needle),
                "BackendKitCore must not reference '\(needle)' — driver-leak silent fail (spec b7e2d4f6)."
            )
        }
    }

    @Test("BackendKitPostgres depends on postgres-nio (the wave's declared driver)")
    func postgresTargetDeclaresItsDriver() throws {
        let manifest = try Self.readManifest()
        guard let range = Self.range(ofTargetNamed: "BackendKitPostgres", in: manifest) else {
            Issue.record("BackendKitPostgres target block not found in Package.swift")
            return
        }
        let block = String(manifest[range])
        #expect(block.contains("PostgresNIO"), "BackendKitPostgres must depend on PostgresNIO")
    }

    @Test("BackendKit lists BackendKitCore and BackendKitPostgres as public products")
    func productsDeclared() throws {
        let manifest = try Self.readManifest()
        #expect(manifest.contains(#".library(name: "BackendKitCore""#))
        #expect(manifest.contains(#".library(name: "BackendKitPostgres""#))
    }

    // MARK: - Platform split

    /// The lines of `block` that mention `needle`.
    private static func lines(of block: String, containing needle: String) -> [Substring] {
        block.split(separator: "\n").filter { $0.contains(needle) }
    }

    @Test("the Postgres drivers are offered on every platform: no platform condition, no compile flag")
    func postgresDriversAreOnEveryPlatform() throws {
        let manifest = try Self.readManifest()
        // Measured live on macOS, an iOS Simulator, a tvOS Simulator and Linux (2026-11-07); the gate that
        // once kept iOS and tvOS out is gone, and must not creep back without the same kind of evidence.
        #expect(!manifest.contains("serverPlatforms"))
        #expect(!manifest.contains("BACKENDKIT_POSTGRES"))
        guard let range = Self.range(ofTargetNamed: "BackendKitPostgres", in: manifest) else {
            Issue.record("BackendKitPostgres target block not found in Package.swift")
            return
        }
        let block = String(manifest[range])
        for driver in ["PostgresNIO", "PostgresKit"] {
            let declarations = Self.lines(of: block, containing: "name: \"\(driver)\"")
            #expect(declarations.count == 1, "\(driver) must be declared exactly once")
            #expect(
                declarations.allSatisfy { !$0.contains("condition:") },
                "\(driver) must not carry a platform condition: Postgres runs on iOS and tvOS (measured)"
            )
        }
    }

    @Test("Core, SQL and SQLite stay engine-neutral — they never reach a Postgres driver")
    func iosCapableTargetsAvoidPostgres() throws {
        let manifest = try Self.readManifest()
        for name in ["BackendKitCore", "BackendKitSQL", "BackendKitSQLite"] {
            guard let range = Self.range(ofTargetNamed: name, in: manifest) else {
                Issue.record("\(name) target block not found in Package.swift")
                continue
            }
            let block = String(manifest[range])
            for forbidden in ["PostgresNIO", "PostgresKit", "postgres-nio", "postgres-kit", "BackendKitPostgres"] {
                #expect(!block.contains(forbidden), "\(name) must not reach '\(forbidden)': it is engine-neutral, and a consumer of it pays for no other engine")
            }
        }
    }

    @Test("DuckDB is offered on Apple platforms only, and the manifest names the upstream Linux failure")
    func duckDBIsAppleOnly() throws {
        let manifest = try Self.readManifest()
        let declaration = Self.lines(of: manifest, containing: "let duckDBPlatforms")
        #expect(declaration.count == 1)
        #expect(declaration.first?.contains(".linux") == false, "duckdb-swift does not compile on Linux; add .linux only with a Linux job that proves it")
        #expect(declaration.first?.contains(".macOS") == true)
        #expect(manifest.contains("_mantissa"), "the Linux exclusion must name the upstream failure it stands on")
        guard let range = Self.range(ofTargetNamed: "BackendKitDuckDB", in: manifest) else {
            Issue.record("BackendKitDuckDB target block not found in Package.swift")
            return
        }
        let block = String(manifest[range])
        let driver = Self.lines(of: block, containing: "package: \"duckdb-swift\"")
        #expect(driver.count == 1)
        #expect(driver.allSatisfy { $0.contains("condition: .when(platforms: duckDBPlatforms)") })
        #expect(block.contains(#".define("BACKENDKIT_DUCKDB", .when(platforms: duckDBPlatforms))"#))
    }

    @Test("the Linux pipeline exists and builds the test targets too")
    func linuxPipelineIsDeclared() throws {
        let pipeline = try String(
            contentsOf: TestPackagePaths.packageRoot().appendingPathComponent(".woodpecker/linux-build.yml"),
            encoding: .utf8
        )
        #expect(pipeline.contains("platform: linux/amd64"))
        #expect(pipeline.contains("swift build --build-tests"))
        #expect(pipeline.contains("swift test --skip-build"))
        #expect(pipeline.contains("manual"))
    }

    // MARK: - Helper

    /// Return the range covering `.target(name: "<name>", …)` — from the
    /// `.target(` marker up to the matching closing paren at depth 0.
    private static func range(ofTargetNamed name: String, in manifest: String) -> Range<String.Index>? {
        let marker = ".target(\n            name: \"\(name)\","
        // Fall back to a looser search if the exact whitespace shape drifts.
        var start = manifest.range(of: marker)?.lowerBound
        if start == nil {
            let looseMarker = "name: \"\(name)\""
            guard let nameRange = manifest.range(of: looseMarker) else { return nil }
            // Walk backwards to the nearest `.target(`.
            let prefix = manifest[..<nameRange.lowerBound]
            guard let dotTarget = prefix.range(of: ".target(", options: .backwards) else { return nil }
            start = dotTarget.lowerBound
        }
        guard let openMarker = manifest.range(of: ".target(", range: start!..<manifest.endIndex) else {
            return nil
        }
        // Walk paren depth from the '(' that opens `.target(`.
        var depth = 0
        var idx = openMarker.upperBound // just past `.target(`
        depth = 1
        while idx < manifest.endIndex {
            let ch = manifest[idx]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { return start!..<manifest.index(after: idx) }
            }
            idx = manifest.index(after: idx)
        }
        return nil
    }
}
