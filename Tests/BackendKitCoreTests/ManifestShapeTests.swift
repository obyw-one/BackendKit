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

    @Test("DuckDB is offered on every platform: duckdb-swift on Apple, the official libduckdb (CDuckDB) on Linux, no gate left")
    func duckDBIsOnEveryPlatform() throws {
        let manifest = try Self.readManifest()
        // The Linux gate and its flag are gone; the platform lists name which binding each platform uses.
        #expect(!manifest.contains("duckDBPlatforms"), "the Linux gate on DuckDB is removed; do not bring it back")
        #expect(!manifest.contains("BACKENDKIT_DUCKDB"), "there is no compile flag: the driver is chosen by the operating system")
        let apple = Self.lines(of: manifest, containing: "let duckDBSwiftPlatforms")
        #expect(apple.count == 1)
        #expect(apple.first?.contains(".linux") == false, "duckdb-swift does not compile on Linux")
        #expect(apple.first?.contains(".macOS") == true && apple.first?.contains(".iOS") == true && apple.first?.contains(".tvOS") == true)
        let linux = Self.lines(of: manifest, containing: "let libDuckDBPlatforms")
        #expect(linux.count == 1)
        #expect(linux.first?.contains("[.linux]") == true)
        #expect(manifest.contains("_mantissa"), "the manifest must keep naming the upstream failure that keeps duckdb-swift off Linux")

        guard let range = Self.range(ofTargetNamed: "BackendKitDuckDB", in: manifest) else {
            Issue.record("BackendKitDuckDB target block not found in Package.swift")
            return
        }
        let block = String(manifest[range])
        let swiftBinding = Self.lines(of: block, containing: "package: \"duckdb-swift\"")
        #expect(swiftBinding.count == 1)
        #expect(swiftBinding.allSatisfy { $0.contains("condition: .when(platforms: duckDBSwiftPlatforms)") })
        #expect(block.contains("duckDBLinuxDependencies"), "the Linux dependency (CDuckDB) is attached to the DuckDB target")
        #expect(manifest.contains(#".target(name: "CDuckDB", condition: .when(platforms: libDuckDBPlatforms))"#))
        #expect(manifest.contains(#".systemLibrary(name: "CDuckDB", pkgConfig: "duckdb")"#))
    }

    @Test("no DuckDB binary is committed or fetched by the manifest: Linux links an installed, checksum-verified library")
    func noBinaryInTheRepository() throws {
        let manifest = try Self.readManifest()
        #expect(!manifest.contains(".binaryTarget"), "libduckdb is installed by Scripts/install-libduckdb.sh, not shipped as a binary target")
        #expect(!manifest.contains("unsafeFlags"), "no unsafe flags: the library path comes from pkg-config")
        let root = TestPackagePaths.packageRoot()
        let binaryExtensions: Set<String> = ["so", "a", "dylib", "xcframework", "dll", "lib", "zip", "gz"]
        for directory in ["Sources", "Scripts", "Tests"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker {
                #expect(!binaryExtensions.contains(file.pathExtension), "\(file.lastPathComponent) looks like a committed binary or archive")
            }
        }
    }

    @Test("the facade: one engine over a driver protocol, two drivers, the platform chosen in exactly one place")
    func facadeShape() throws {
        let sources = TestPackagePaths.packageRoot().appendingPathComponent("Sources/BackendKitDuckDB")
        let names = try FileManager.default.contentsOfDirectory(atPath: sources.path)
        #expect(!names.contains("DuckDBUnavailable.swift"), "DuckDB is no longer unavailable anywhere")
        func text(_ name: String) throws -> String { try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8) }
        // Only the two drivers and the selection line know a binding exists.
        let bindingFiles = ["DuckDBSwiftDriver.swift", "DuckDBCAPIDriver.swift"]
        for name in names where name.hasSuffix(".swift") && !bindingFiles.contains(name) {
            let source = try text(name)
            #expect(!source.contains("import DuckDB\n") && !source.contains("import CDuckDB"), "\(name) must not import a DuckDB binding: that is the driver's job")
            if name != "DuckDBDriverProtocol.swift" {
                #expect(!source.contains("#if os("), "\(name) must not branch on the platform: the facade does that once")
            }
        }
        #expect(try text("DuckDBDriverProtocol.swift").components(separatedBy: "#if os(").count == 2, "the platform is selected in one #if chain")
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
        // The DuckDB library is installed, verified, and made visible to both pkg-config and the dynamic loader.
        #expect(pipeline.contains("sh Scripts/install-libduckdb.sh"))
        #expect(pipeline.contains("PKG_CONFIG_PATH") && pipeline.contains("LD_LIBRARY_PATH"))
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
