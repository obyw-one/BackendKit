import BackendKitDuckDB
import BackendKitSQL
import Foundation
import SQLKit
import SQLKitBenchmark
import Testing
import XCTest

struct Note: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let count: Int
}

// SQLKit's own driver-conformance suite against the DuckDB driver (spec b4f8c3a1 W3 gate).
// `SQLBenchmarker.runAllTests()` = testPlanets + testCodable + testEnum + testUpserts +
// testUnions + testJSONPaths. Each public sub-suite runs on its own so a failure names itself.
// `testPlanets` is NOT run here: it issues `SELECT * FROM galaxies ... GROUP BY id`, which
// Postgres/SQLite accept (functional dependency on the primary key) and DuckDB rejects with a
// Binder Error. That is a DuckDB SQL-semantics difference, not a driver defect, so
// `DuckDBPlanetsEquivalentTests` replays the same statements minus that one GROUP BY.
final class DuckDBBenchmarkTests: XCTestCase {
    private func withHost(_ body: (SQLBenchmarker) async throws -> Void) async throws {
        let host = try await DuckDBSQLHost.open(storage: .memory)
        do {
            try await body(SQLBenchmarker(on: host.database))
        } catch {
            try? await host.shutdown()
            throw error
        }
        try await host.shutdown()
    }

    func testCodableConformance() async throws { try await withHost { try await $0.testCodable() } }
    func testEnumConformance()  /* enums are .unsupported on DuckDB: SQLKit models them as text */ async throws { try await withHost { try await $0.testEnum() } }
    func testUpsertConformance() async throws { try await withHost { try await $0.testUpserts() } }
    func testUnionConformance() async throws { try await withHost { try await $0.testUnions() } }
    func testJSONPathsConformance() async throws { try await withHost { try await $0.testJSONPaths() } }
}

// `testPlanets` minus its one `GROUP BY id` over `SELECT *` (DuckDB has no functional-dependency
// grouping): schema create/alter/index, DEFAULT-key inserts, binds, counts.
final class DuckDBPlanetsEquivalentTests: XCTestCase {
    func testPlanetsEquivalent() async throws {
        let host = try await DuckDBSQLHost.open(storage: .memory)
        do { try await run(host.database) } catch { try? await host.shutdown(); throw error }
        try await host.shutdown()
    }

    private func run(_ db: any SQLDatabase) async throws {
        try await db.drop(table: "planets").ifExists().run()
        try await db.drop(table: "galaxies").ifExists().run()
        try await db.create(table: "galaxies").column("id", type: .bigint, .primaryKey).column("name", type: .text).run()
        try await db.create(table: "planets").ifNotExists()
            .column("id", type: .bigint, .primaryKey)
            .column("galaxyID", type: .bigint, .references("galaxies", "id"))
            .run()
        try await db.alter(table: "planets").column("name", type: .text, .default(SQLLiteral.string("Unnamed Planet"))).run()
        // DuckDB refuses ALTER TABLE once an index depends on the table, so the extra-column
        // alter (which SQLKit's own testPlanets runs AFTER the index) happens first here.
        try await db.alter(table: "planets").column("extra", type: .int).run()
        try await db.alter(table: "planets").dropColumn("extra").run()
        try await db.create(index: "test_index").on("planets").column("id").unique().run()

        try await db.insert(into: "galaxies").columns("id", "name")
            .values(SQLLiteral.default, SQLBind("Milky Way"))
            .values(SQLLiteral.default, SQLBind("Andromeda"))
            .run()
        let found = try await db.select().column("*").from("galaxies")
            .where("name", .notEqual, SQLLiteral.null)
            .where { $0.where("name", .equal, SQLBind("Milky Way")).orWhere("name", .equal, SQLBind("Andromeda")) }
            .all()
        // `name != NULL` is never true in SQL (three-valued logic), on every engine: 0 rows, not 2.
        XCTAssertEqual(found.count, 0)
        let ordered = try await db.select().column("*").from("galaxies")
            .where(SQLColumn("name"), .equal, SQLBind("Milky Way"))
            .orderBy("name", .descending)
            .all()
        XCTAssertEqual(ordered.count, 1)

        try await db.insert(into: "planets").columns("id", "name").values(SQLLiteral.default, SQLBind("Earth")).run()
        try await db.insert(into: "planets").columns("id", "name")
            .values(SQLLiteral.default, SQLBind("Mercury"))
            .values(SQLLiteral.default, SQLBind("Venus"))
            .run()
        let counted = try await db.select().column(SQLFunction("count", args: SQLLiteral.all)).from("planets").all()
        XCTAssertEqual(try counted.first?.decode(column: "count_star()", as: Int.self), 3)

        try await db.drop(table: "planets").run()
        try await db.drop(table: "galaxies").run()
    }
}

@Suite("SQLRepository — DuckDB round-trip (no server needed)")
struct DuckDBRepositoryTests {
    static let hostile = "x'); DROP TABLE notes; --"

    private func roundTrip(_ host: DuckDBSQLHost) async throws {
        try await host.database.raw("CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL, count INTEGER NOT NULL)").run()
        let repo = SQLRepository<UUID, Note>(database: host.database, table: "notes")
        let note = Note(id: UUID(), title: Self.hostile, count: 7)
        try await repo.save(note.id, data: note)
        #expect(try await repo.get(note.id) == note)

        let updated = Note(id: note.id, title: "renamed", count: 8)
        try await repo.save(updated.id, data: updated)
        #expect(try await repo.list() == [updated])

        // Hostile string stored and read back as data; the table survived.
        try await repo.save(note.id, data: note)
        #expect(try await repo.get(note.id).title == Self.hostile)

        try await repo.delete(note.id)
        await #expect(throws: SQLRepositoryError.self) { _ = try await repo.get(note.id) }
        await #expect(throws: SQLRepositoryError.self) { try await repo.delete(note.id) }
    }

    @Test("in-memory: save / get / list / delete + hostile string as data")
    func memory() async throws {
        let host = try await DuckDBSQLHost.open(storage: .memory)
        do { try await roundTrip(host) } catch { try? await host.shutdown(); throw error }
        try await host.shutdown()
    }

    @Test("file-backed: round-trip, and data persists across a reopen")
    func file() async throws {
        let path = NSTemporaryDirectory() + "backendkit-duckdb-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let host = try await DuckDBSQLHost.open(storage: .file(path: path))
        do { try await roundTrip(host) } catch { try? await host.shutdown(); throw error }
        let repo = SQLRepository<UUID, Note>(database: host.database, table: "notes")
        let kept = Note(id: UUID(), title: Self.hostile, count: 1)
        try await repo.save(kept.id, data: kept)
        try await host.shutdown()

        let reopened = try await DuckDBSQLHost.open(storage: .file(path: path))
        let again = SQLRepository<UUID, Note>(database: reopened.database, table: "notes")
        #expect(try await again.get(kept.id) == kept)
        try await reopened.shutdown()
    }
}
