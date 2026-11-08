import BackendKitMigrations
import BackendKitSQL
import BackendKitSQLite
import CoreKitTestSupport
import Foundation
import SQLKit
import Testing

// MARK: - SQLMigrationStoreTests

//
// BR-MIG-12 / BR-SQL-05: one `MigrationStore` over SQLKit, proven on SQLite, DuckDB and (live) Postgres by
// applying a migrations FOLDER twice. The SQL in the folder is deliberately the portable subset: the store is
// what is under test, not a dialect.

// Serialized: the folder's files register into the literal `schema_migrations` (the kit's ledger rules read that name) and
// create `notes`, so two tests on one live Postgres database must not overlap. SQLite and DuckDB are private per test.
@Suite("SQLMigrationStore — a migrations folder applies once, on every engine", .serialized)
struct SQLMigrationStoreTests {

    private static let scratch = TestScratch.forPackage()

    /// The folder: DDL, an index, seeded rows, and one file that carries its own BEGIN/COMMIT.
    private static let folder: [(name: String, sql: String)] = [
        (
            "0001_notes.sql",
            """
            -- the first table
            CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL);
            INSERT INTO schema_migrations (version) VALUES ('0001_notes');
            """
        ),
        (
            "0002_title_index.sql",
            """
            CREATE INDEX notes_title ON notes (title);
            INSERT INTO schema_migrations (version) VALUES ('0002_title_index');
            """
        ),
        (
            "0010_seed.sql",
            """
            BEGIN;
            INSERT INTO notes (id, title) VALUES ('a', 'alpha; with a semicolon'), ('b', 'beta');
            INSERT INTO schema_migrations (version) VALUES ('0010_seed');
            COMMIT;
            """
        ),
    ]

    private func makeFolder(_ files: [(name: String, sql: String)]) throws -> URL {
        let directory = try Self.scratch.makeScratchDir(scope: "migration-store")
        for file in files {
            try file.sql.write(to: directory.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
        }
        return directory
    }

    private func removeFolder(_ directory: URL) {
        do {
            try Self.scratch.removeScratchDir(directory)
        } catch {
            Issue.record("could not remove \(directory.path): \(error)")
        }
    }

    /// An engine with a fresh ledger table, and the store over it. Both tables are dropped afterwards, so a shared
    /// Postgres is left as it was found.
    private func withStore<Result: Sendable>(
        _ engine: ResourceEngine, _ body: @Sendable (ResourceSession, SQLMigrationStore, MigrationLedgerContract) async throws -> Result
    ) async throws -> Result {
        try await engine.open().use { session in
            let contract = MigrationLedgerContract()
            try await session.createLedger(contract)
            do {
                let result = try await body(session, SQLMigrationStore(database: session.database, contract: contract), contract)
                try await session.dropAll(["notes", contract.tableName])
                return result
            } catch {
                throw await SessionError.afterClosing({ try await session.dropAll(["notes", contract.tableName]) }, failure: error)
            }
        }
    }

    private func rowCount(_ session: ResourceSession, _ table: String) async throws -> Int {
        try await session.database.select().column("id").from(table).all().count
    }

    @Test("applying the folder twice changes nothing the second time", arguments: ResourceEngine.available)
    func folderIsIdempotent(engine: ResourceEngine) async throws {
        let directory = try makeFolder(Self.folder)
        defer { removeFolder(directory) }
        try await withStore(engine) { session, store, _ in
            let first = try await store.applyAll(in: directory)
            #expect(first.map(\.version) == ["0001_notes", "0002_title_index", "0010_seed"])
            #expect(first.allSatisfy { $0.applied })
            #expect(first.map(\.gained) == [["0001_notes"], ["0002_title_index"], ["0010_seed"]])
            #expect(first.allSatisfy { $0.lost.isEmpty })
            #expect(try await rowCount(session, "notes") == 2)

            let second = try await store.applyAll(in: directory)
            #expect(second.map(\.version) == first.map(\.version))
            #expect(second.allSatisfy { !$0.applied && $0.gained.isEmpty && $0.lost.isEmpty }, "the second run applied something: \(second)")
            #expect(try await rowCount(session, "notes") == 2, "the seed ran twice")

            #expect(try await store.appliedMigrationVersions() == ["0001_notes", "0002_title_index", "0010_seed"])
            let shipped = try MigrationManifest.versions(in: directory)
            #expect(try await store.missing(from: shipped).isEmpty)
        }
    }

    @Test("a new file in the folder is the only thing the next run applies", arguments: ResourceEngine.available)
    func newFileAppliesAlone(engine: ResourceEngine) async throws {
        let directory = try makeFolder(Self.folder)
        defer { removeFolder(directory) }
        try await withStore(engine) { session, store, _ in
            try await store.applyAll(in: directory)
            try """
            INSERT INTO notes (id, title) VALUES ('c', 'gamma');
            INSERT INTO schema_migrations (version) VALUES ('0011_more');
            """.write(to: directory.appendingPathComponent("0011_more.sql"), atomically: true, encoding: .utf8)
            let shipped = try MigrationManifest.versions(in: directory)
            #expect(try await store.missing(from: shipped) == ["0011_more"])
            let run = try await store.applyAll(in: directory)
            #expect(run.filter(\.applied).map(\.version) == ["0011_more"])
            #expect(try await rowCount(session, "notes") == 3)
        }
    }

    @Test("a statement that fails rolls the whole file back: no table, no ledger row", arguments: ResourceEngine.available)
    func failureRollsBack(engine: ResourceEngine) async throws {
        let directory = try makeFolder([
            (
                "0001_broken.sql",
                """
                CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL);
                INSERT INTO notes (id, title) VALUES ('a', 'alpha');
                INSERT INTO no_such_table (id) VALUES ('boom');
                INSERT INTO schema_migrations (version) VALUES ('0001_broken');
                """
            ),
        ])
        defer { removeFolder(directory) }
        try await withStore(engine) { session, store, _ in
            do {
                try await store.applyMigration(at: directory.appendingPathComponent("0001_broken.sql"))
                Issue.record("a broken migration was reported as applied")
            } catch MigrationApplyError.driverFailed(let file, let underlying) {
                #expect(file == "0001_broken.sql")
                #expect(!"\(underlying)".isEmpty, "the engine's cause was dropped")
            } catch {
                Issue.record("wrong error: \(error)")
            }
            #expect(try await store.appliedMigrationVersions().isEmpty, "the ledger kept a row of a rolled-back file")
            await #expect(throws: (any Error).self, "the table of a rolled-back file survived") {
                _ = try await session.database.select().column("id").from("notes").all()
            }
            // The connection is usable again: a good migration applies right after the failure.
            try "CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL);\nINSERT INTO schema_migrations (version) VALUES ('0002_good');\n"
                .write(to: directory.appendingPathComponent("0002_good.sql"), atomically: true, encoding: .utf8)
            let outcome = try await store.applyMigration(at: directory.appendingPathComponent("0002_good.sql"))
            #expect(outcome.applied && outcome.gained == ["0002_good"])
        }
    }

    @Test("a file that registers the wrong version is refused before the engine sees a statement", arguments: ResourceEngine.available)
    func ledgerViolationTouchesNothing(engine: ResourceEngine) async throws {
        let directory = try makeFolder([
            (
                "0001_liar.sql",
                "CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL);\nINSERT INTO schema_migrations (version) VALUES ('0001_other');\n"
            ),
        ])
        defer { removeFolder(directory) }
        try await withStore(engine) { session, store, _ in
            await #expect(throws: MigrationApplyError.self) {
                try await store.applyMigration(at: directory.appendingPathComponent("0001_liar.sql"))
            }
            await #expect(throws: (any Error).self, "the refused file's table was created anyway") {
                _ = try await session.database.select().column("id").from("notes").all()
            }
            let applied = try await store.appliedMigrationVersions()
            #expect(applied.isEmpty)
        }
    }

    @Test("a ledger that was never created is the engine's error, not an empty ledger", arguments: ResourceEngine.available)
    func missingLedgerSurfaces(engine: ResourceEngine) async throws {
        try await engine.open().use { session in
            let store = SQLMigrationStore(database: session.database, contract: MigrationLedgerContract(tableName: "never_created"))
            await #expect(throws: (any Error).self) { _ = try await store.appliedMigrationVersions() }
        }
    }

    @Test("the ledger table is created idempotently and keeps the version column the contract selects", arguments: ResourceEngine.available)
    func ledgerShape(engine: ResourceEngine) async throws {
        try await withStore(engine) { session, store, contract in
            try await session.createLedger(contract)
            try await session.database.insert(into: contract.tableName).columns(["version"]).values(SQLBind("0001_x")).run()
            #expect(try await store.appliedMigrationVersions() == ["0001_x"])
            // The default timestamp was filled by the engine.
            let rows = try await session.database.select().column("applied_at").from(contract.tableName).all()
            let stamp = try #require(try rows.first?.decode(column: "applied_at", as: String.self))
            #expect(!stamp.isEmpty)
            #expect(contract.selectAllVersionsSQL.contains("version"))
        }
    }
}
