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
