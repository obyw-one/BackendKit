import CoreKit
import Foundation
import PostgresNIO
import Testing
@testable import BackendKitCore
@testable import BackendKitPostgres

// MARK: - LiveTestEnvKey

/// The one switch this test target reads, declared as a CoreKit
/// `EnvironmentKey` (BackendKit #2 review: no raw `environment["…"]`).
private enum LiveTestEnvKey: String, EnvironmentKey {
    case liveTests = "BACKENDKIT_LIVE_TESTS"
}

// MARK: - RepositoryLiveTests

//
// T-04 (spec b7e2d4f6, phase 4): when `BACKENDKIT_LIVE_TESTS=1`, a
// `PostgresRepository<UUID, Sample>` round-trips a Codable model against a
// live Postgres. Gated by env var so the package's test target is green
// without a database — CI without Postgres skips it, a developer with
// shikki-db running exercises it. The process env is snapshotted ONCE through
// `TypedEnvironment.current()` and handed to the resolver.

@Suite("PostgresRepository — live Codable round-trip (BACKENDKIT_LIVE_TESTS=1)")
struct RepositoryLiveTests {
    // MARK: - Fixture model

    struct Sample: Codable, Equatable, Sendable {
        let title: String
        let count: Int
    }

    // MARK: - Gate

    private static let environment = TypedEnvironment.current()

    static var isLive: Bool {
        environment.flag(LiveTestEnvKey.liveTests)
    }

    // MARK: - T-04

    @Test(
        "save / get / list / delete round-trip against a live Postgres",
        .enabled(if: isLive)
    )
    func liveRoundTrip() async throws {
        let connection = PostgresConnectionConfig(
            environment: Self.environment,
            firstChoicePrefix: "SHIKKI_DB_"
        )
        let host = PostgresClientHost(connection: connection, reconnect: false)
        defer { host.close() }

        let table = "backendkit_live_test_\(Int.random(in: 100_000...999_999))"
        try await createTable(client: host.client, name: table)
        defer { Task { try? await dropTable(client: host.client, name: table) } }

        let repo = PostgresRepository<UUID, Sample>(client: host.client, table: table)
        let id = UUID()
        let payload = Sample(title: "hello", count: 3)

        try await repo.save(id, data: payload)
        let fetched = try await repo.get(id)
        #expect(fetched == payload)

        let listed = try await repo.list()
        #expect(listed.contains(payload))

        try await repo.delete(id)
        do {
            _ = try await repo.get(id)
            Issue.record("expected PostgresRepositoryError.notFound after delete")
        } catch PostgresRepositoryError.notFound {
            // expected
        }
    }

    // MARK: - Helpers

    private func createTable(client: PostgresClient, name: String) async throws {
        let sql = "CREATE TABLE \(name) (id uuid PRIMARY KEY, model jsonb NOT NULL)"
        _ = try await client.query(PostgresQuery(unsafeSQL: sql, binds: PostgresBindings()))
    }

    private func dropTable(client: PostgresClient, name: String) async throws {
        let sql = "DROP TABLE IF EXISTS \(name)"
        _ = try await client.query(PostgresQuery(unsafeSQL: sql, binds: PostgresBindings()))
    }
}
