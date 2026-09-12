import Foundation
import Testing
@testable import BackendKitCore

// MARK: - RatchetHelperTests

//
// T-05 (spec b7e2d4f6, phase 4): given a fixture tree containing a field
// access on a fresh resolver and a raw env read outside the resolver, the
// scan reports BOTH lines with `file:line`. Also confirms the resolver's own
// file (config type name) is exempted so the ratchet does not flag its own
// definition.

@Suite("ConnectionInjectionRatchet — the scan helper every consumer runs")
struct RatchetHelperTests {
    // MARK: - Fixture writer

    private func makeFixtureTree(files: [String: String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backendkit-ratchet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for (relative, content) in files {
            let url = base.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return base
    }

    // MARK: - T-05

    @Test("both a field access and a raw env read are reported with file:line")
    func fieldAccessAndRawEnvBothReported() throws {
        let tree = try makeFixtureTree(files: [
            "Consumer/Store.swift": """
            import Foundation
            let host = PostgresConnectionConfig().host
            let user = ProcessInfo.processInfo.environment["PGHOST"]
            """,
            // The resolver's own file must be exempt — the same shape here is
            // "the resolver", not a caller violating the seam.
            "PostgresConnectionConfig.swift": """
            struct PostgresConnectionConfig { let host = "127.0.0.1" }
            let x = PostgresConnectionConfig().host
            let y = ProcessInfo.processInfo.environment["PGHOST"]
            """,
        ])
        defer { try? FileManager.default.removeItem(at: tree) }

        let result = try ConnectionInjectionRatchet.scan(sourcesRoot: tree)

        #expect(result.fieldAccess == ["Sources/Consumer/Store.swift:2"])
        #expect(result.rawEnvReads == ["Sources/Consumer/Store.swift:3"])
    }

    @Test("comment lines are not flagged")
    func commentsAreExempt() throws {
        let tree = try makeFixtureTree(files: [
            "Consumer/Docs.swift": """
            // let bad = PostgresConnectionConfig().host
            // let leak = ProcessInfo.processInfo.environment["PGHOST"]
            let ok = 1
            """,
        ])
        defer { try? FileManager.default.removeItem(at: tree) }

        let result = try ConnectionInjectionRatchet.scan(sourcesRoot: tree)
        #expect(result.fieldAccess.isEmpty)
        #expect(result.rawEnvReads.isEmpty)
    }

    @Test("consumer prefixes are watched alongside PG*")
    func consumerPrefixesAreWatched() throws {
        let tree = try makeFixtureTree(files: [
            "Consumer/Config.swift": """
            let host = env["SHIKKI_DB_HOST"]
            let port = env["SHIKKI_DB_PORT"]
            let noise = env["SHIKKI_DB_URL"]
            let admin = env["SHIKKI_DB_ADMIN_TOKEN"]
            """,
        ])
        defer { try? FileManager.default.removeItem(at: tree) }

        let result = try ConnectionInjectionRatchet.scan(
            sourcesRoot: tree,
            firstChoicePrefixes: ["SHIKKI_DB_"]
        )
        // The two connection keys (HOST, PORT) are reported; unrelated
        // SHIKKI_DB_ names (URL, ADMIN_TOKEN) are NOT — they are not the
        // resolver's business.
        #expect(
            result.rawEnvReads == [
                "Sources/Consumer/Config.swift:1",
                "Sources/Consumer/Config.swift:2",
            ]
        )
    }

    @Test("ownerFiles are exempt from BOTH rules")
    func ownerFilesAreExempt() throws {
        let tree = try makeFixtureTree(files: [
            "Consumer/Owner.swift": """
            let host = PostgresConnectionConfig().host
            let leak = env["PGHOST"]
            """,
        ])
        defer { try? FileManager.default.removeItem(at: tree) }

        let result = try ConnectionInjectionRatchet.scan(
            sourcesRoot: tree,
            ownerFiles: ["Sources/Consumer/Owner.swift"]
        )
        #expect(result.fieldAccess.isEmpty)
        #expect(result.rawEnvReads.isEmpty)
    }

    @Test("missing sources directory throws a RatchetError")
    func missingSourcesRootThrows() {
        let ghost = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        #expect(throws: ConnectionInjectionRatchet.RatchetError.self) {
            try ConnectionInjectionRatchet.scan(sourcesRoot: ghost)
        }
    }
}
