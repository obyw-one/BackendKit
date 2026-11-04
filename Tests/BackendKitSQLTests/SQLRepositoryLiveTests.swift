import BackendKitPostgres
import Foundation
import SQLKit
import Testing
@testable import BackendKitSQL

// MARK: - SQLRepositoryLiveTests

//
// T-04 / T-08 (spec b4f8c3a1): a Codable model round-trips through `SQLRepository` on a live
// Postgres, and a `'; DROP TABLE` value stored then read back is still data. Gated by
// BACKENDKIT_LIVE_TESTS=1 (+ PGHOST/PGPORT/PGUSER/PGDATABASE) like the engine's other live suite.

@Suite("SQLRepository — live Postgres round-trip (BACKENDKIT_LIVE_TESTS=1)")
struct SQLRepositoryLiveTests {
    static let hostile = "x'); DROP TABLE live_notes; --"

    @Test("save / get / list / delete round-trip, hostile string survives as data", .enabled(if: LiveDatabase.isLive))
    func roundTrip() async throws {
        let host = PostgresSQLHost(connection: LiveDatabase.connection())
        let table = "backendkit_sql_live_\(Int.random(in: 100_000...999_999))"
        try await host.database.raw("CREATE TABLE \(unsafeRaw: table) (id uuid PRIMARY KEY, title text NOT NULL, count bigint NOT NULL)").run()

        do {
            let repo = SQLRepository<UUID, Note>(database: host.database, table: table)
            let note = Note(id: UUID(), title: Self.hostile, count: 7)
            try await repo.save(note.id, data: note)
            #expect(try await repo.get(note.id) == note)

            let updated = Note(id: note.id, title: "renamed", count: 8)
            try await repo.save(updated.id, data: updated)
            #expect(try await repo.list() == [updated])

            // The table is still there after the hostile value: it was data, not SQL.
            try await repo.save(note.id, data: note)
            #expect(try await repo.get(note.id).title == Self.hostile)

            try await repo.delete(note.id)
            await #expect(throws: SQLRepositoryError.self) { _ = try await repo.get(note.id) }
            await #expect(throws: SQLRepositoryError.self) { try await repo.delete(note.id) }
        } catch {
            try? await host.database.raw("DROP TABLE IF EXISTS \(unsafeRaw: table)").run()
            try? await host.shutdown()
            throw error
        }
        try await host.database.raw("DROP TABLE IF EXISTS \(unsafeRaw: table)").run()
        try await host.shutdown()
    }
}
