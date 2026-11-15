import BackendKitSQL
import CoreKit
import Foundation
import SQLKit
import Testing

// MARK: - SQLCacheBackingTests

//
// What the conformance suites do not say, because it belongs to a table: the (bucket, node, entry) key, the rows
// the backing leaves alone, names that are hostile as SQL, and what an engine failure looks like to the caller.

@Suite("SQLCacheBacking — the table's own behaviour")
struct SQLCacheBackingTests {

    private static let hostileNames = [
        "x'); DROP TABLE evidence; --", "../../escape", "a/b/c", "with space", "quote\"d", "emoji-🦆-é", "100%_like", "back\\slash",
    ]

    @Test("a hostile entry name is data: it round-trips and the table survives", arguments: ResourceEngine.available)
    func hostileNamesAreData(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let backing = ResourceBackingHarness.backing(session)
            for name in Self.hostileNames {
                try await backing.put(Data(name.utf8), as: name)
            }
            for name in Self.hostileNames {
                #expect(try await backing.fetch(name)?.data == Data(name.utf8), "\(name) did not round-trip")
            }
            #expect(Set(try await backing.entries()) == Set(Self.hostileNames))
        }
    }

    @Test("three nodes writing one entry name write three rows", arguments: ResourceEngine.available)
    func nodesDoNotCollide(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let nodes: [NodeID] = ["mac-a", "mac-b", "mac-ab"]
            for node in nodes {
                try await ResourceBackingHarness.backing(session, node: node).put(Data(node.description.utf8), as: "spec-evidence")
            }
            for node in nodes {
                let backing = ResourceBackingHarness.backing(session, node: node)
                #expect(try await backing.fetch("spec-evidence")?.data == Data(node.description.utf8))
                #expect(try await backing.entries() == ["spec-evidence"], "node \(node) lists another node's rows")
            }
            // A consolidation step reads another node's rows by scoping the same backing.
            let consolidating = ResourceBackingHarness.backing(session, node: "mac-a").scoped(to: "mac-b")
            #expect(try await consolidating.fetch("spec-evidence")?.data == Data("mac-b".utf8))
            #expect(try await consolidating.delete("spec-evidence"))
            #expect(try await ResourceBackingHarness.backing(session, node: "mac-a").has("spec-evidence"), "deleting mac-b's row removed mac-a's")
        }
    }

    @Test("two buckets over one table are two caches", arguments: ResourceEngine.available)
    func bucketsAreIsolated(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let evidence = ResourceBackingHarness.backing(session)
            let reports = SQLCacheBacking(database: session.database, table: session.cacheTable, bucket: "reports", node: ResourceBackingHarness.node)
            try await evidence.put(Data("e".utf8), as: "same")
            try await reports.put(Data("r".utf8), as: "same")
            #expect(try await evidence.fetch("same")?.data == Data("e".utf8))
            #expect(try await reports.fetch("same")?.data == Data("r".utf8))
            #expect(try await reports.delete("same"))
            #expect(try await evidence.has("same"))
        }
    }

    @Test("an overwrite keeps one row and moves modified forward", arguments: ResourceEngine.available)
    func overwriteMovesModified(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            // Two backings over one table, one clock a minute ahead of the other: the same entry, written twice.
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            func backing(at moment: Date) -> SQLCacheBacking {
                SQLCacheBacking(
                    database: session.database, table: session.cacheTable, bucket: ResourceBackingHarness.bucket,
                    node: ResourceBackingHarness.node, clock: { moment })
            }
            try await backing(at: start).put(Data("1".utf8), as: "entry")
            let later = backing(at: start.addingTimeInterval(60))
            #expect(try await later.fetch("entry")?.modified == start)
            try await later.put(Data("2".utf8), as: "entry")
            #expect(try await later.fetch("entry")?.modified == start.addingTimeInterval(60), "the second write's clock reading was not stored")
            #expect(try await later.entries() == ["entry"])
        }
    }

    @Test("the empty entry name addresses nothing and is refused, as an object store refuses it", arguments: ResourceEngine.available)
    func emptyNameIsRefused(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let backing = ResourceBackingHarness.backing(session)
            let expected = CacheBackingError.invalidEntryName(entry: "", reason: "an entry name cannot be empty")
            await #expect(throws: expected) { try await backing.put(Data(), as: "") }
            await #expect(throws: expected) { _ = try await backing.fetch("") }
            await #expect(throws: expected) { _ = try await backing.delete("") }
            await #expect(throws: expected) { _ = try await backing.has("") }
        }
    }

    @Test("an engine failure is thrown with its cause, never read as 'absent'", arguments: ResourceEngine.available)
    func engineFailureSurfaces(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let broken = SQLCacheBacking(
                database: session.database, table: "no_such_table_\(UUID().uuidString.prefix(8).lowercased())",
                bucket: ResourceBackingHarness.bucket, node: ResourceBackingHarness.node)
            await #expect(throws: (any Error).self) { _ = try await broken.fetch("entry") }
            await #expect(throws: (any Error).self) { _ = try await broken.has("entry") }
            await #expect(throws: (any Error).self) { _ = try await broken.delete("entry") }
            await #expect(throws: (any Error).self) { _ = try await broken.entries() }
            await #expect(throws: (any Error).self) { try await broken.put(Data("x".utf8), as: "entry") }
            do {
                _ = try await broken.fetch("entry")
            } catch {
                #expect(!"\(error)".isEmpty, "the engine's error carries no description")
                #expect(!(error is CacheBackingError), "an engine failure was reworded as a contract refusal: \(error)")
            }
        }
    }

    @Test("the table is keyed (bucket, node, entry): the engine itself refuses a duplicate row", arguments: ResourceEngine.available)
    func schemaEnforcesTheKey(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            typealias Column = SQLCacheBackingSchema.Column
            func insert() async throws {
                try await session.database.insert(into: session.cacheTable)
                    .columns(Column.allCases.map(\.rawValue))
                    .values(SQLBind("evidence"), SQLBind("mac-a"), SQLBind("dup"), SQLBind(Data("x".utf8)), SQLBind(Int64(1)))
                    .run()
            }
            try await insert()
            await #expect(throws: (any Error).self) { try await insert() }
        }
    }

    @Test("creating the table twice is harmless (IF NOT EXISTS), and the rows survive it", arguments: ResourceEngine.available)
    func createIsIdempotent(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let backing = ResourceBackingHarness.backing(session)
            try await backing.put(Data("kept".utf8), as: "entry")
            if engine != .sqlite {
                try await SQLCacheBackingSchema.create(on: session.database, table: session.cacheTable)
            }
            #expect(try await backing.fetch("entry")?.data == Data("kept".utf8))
        }
    }
}
